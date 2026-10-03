// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AlgebraFactory} from "@cryptoalgebra/integral-core/contracts/AlgebraFactory.sol";
import {AlgebraPoolDeployer} from "@cryptoalgebra/integral-core/contracts/AlgebraPoolDeployer.sol";
import {IAlgebraPool} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";

import {KeeperFeePlugin} from "../src/KeeperFeePlugin.sol";
import {KeeperFeePluginFactory} from "../src/KeeperFeePluginFactory.sol";

contract MockToken is ERC20 {
    constructor(string memory s) ERC20(s, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Runs against the real Algebra Integral v1.2.2 factory, deployer and pool (lib/Algebra, tag v1.2.2-integral).
contract KeeperFeePluginTest is Test {
    uint24 constant MIN_FEE = 500; // 5 bp
    uint24 constant MAX_FEE = 10_000; // 100 bp
    uint24 constant INITIAL_FEE = 3000; // 30 bp
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// IAlgebraPoolEvents.SwapFee(address indexed sender, uint24 overrideFee, uint24 pluginFee)
    bytes32 constant SWAP_FEE_EVENT = keccak256("SwapFee(address,uint24,uint24)");

    address keeperAddr = makeAddr("keeper");
    AlgebraFactory algebraFactory;
    KeeperFeePluginFactory pluginFactory;
    MockToken token0;
    MockToken token1;
    IAlgebraPool pool;
    KeeperFeePlugin plugin;

    function setUp() public {
        // AlgebraPoolDeployer and AlgebraFactory reference each other: precompute the factory address.
        address factoryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        AlgebraPoolDeployer poolDeployer = new AlgebraPoolDeployer(factoryAddr);
        algebraFactory = new AlgebraFactory(address(poolDeployer));
        assertEq(address(algebraFactory), factoryAddr);

        MockToken a = new MockToken("A");
        MockToken b = new MockToken("B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);

        pluginFactory = new KeeperFeePluginFactory(address(this), keeperAddr, MIN_FEE, MAX_FEE, INITIAL_FEE);
        (pool, plugin) = _newPool(true);
        pool.mint(address(this), address(this), -6000, 6000, 1e24, "");
    }

    /// Create a pool and attach a KeeperFeePlugin as the pool administrator (this contract owns the factory).
    function _newPool(bool attachBeforeInit) internal returns (IAlgebraPool p, KeeperFeePlugin pl) {
        MockToken t = new MockToken("C");
        t.mint(address(this), 1e30);
        address tokenA = attachBeforeInit ? address(token0) : address(t);
        p = IAlgebraPool(algebraFactory.createPool(tokenA, address(token1), ""));

        if (!attachBeforeInit) p.initialize(SQRT_PRICE_1_1);
        pl = KeeperFeePlugin(pluginFactory.createPlugin(address(p)));
        p.setPlugin(address(pl));
        if (attachBeforeInit) {
            p.initialize(SQRT_PRICE_1_1); // beforeInitialize turns on BEFORE_SWAP + DYNAMIC_FEE
        } else {
            p.setPluginConfig(pl.defaultPluginConfig());
        }
    }

    // --- Algebra callbacks ------------------------------------------------

    function algebraMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        _pay(msg.sender, amount0Owed, amount1Owed);
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(msg.sender, amount0Delta > 0 ? uint256(amount0Delta) : 0, amount1Delta > 0 ? uint256(amount1Delta) : 0);
    }

    function _pay(address p, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) ERC20(IAlgebraPool(p).token0()).transfer(p, amount0);
        if (amount1 > 0) ERC20(IAlgebraPool(p).token1()).transfer(p, amount1);
    }

    // --- Helpers ------------------------------------------------------------

    /// Exact-input swap. Returns the fee the pool charged (from its SwapFee event) and the output amount.
    function _swap(IAlgebraPool p, bool zeroToOne, uint256 amountIn) internal returns (uint24 fee, uint256 amountOut) {
        vm.recordLogs();
        (int256 amount0, int256 amount1) =
            p.swap(address(this), zeroToOne, int256(amountIn), zeroToOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, "");
        amountOut = uint256(-(zeroToOne ? amount1 : amount0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(p) && logs[i].topics[0] == SWAP_FEE_EVENT) {
                (uint24 overrideFee, uint24 pluginFee) = abi.decode(logs[i].data, (uint24, uint24));
                assertEq(pluginFee, 0);
                return (overrideFee, amountOut);
            }
        }
        revert("no SwapFee event");
    }

    function _swapFee() internal returns (uint24 fee) {
        (fee,) = _swap(pool, true, 1e15);
    }

    // --- Tests --------------------------------------------------------------

    function test_attach_setsDynamicFeeConfig() public view {
        (,,, uint8 pluginConfig,,) = pool.globalState();
        assertEq(pluginConfig, plugin.defaultPluginConfig());
        assertEq(pool.plugin(), address(plugin));
        assertEq(pluginFactory.pluginByPool(address(pool)), address(plugin));
    }

    function test_initialFee_quoteEqualsFill() public {
        uint24 quoted = plugin.feeFor();
        assertEq(quoted, INITIAL_FEE);
        assertEq(_swapFee(), quoted);
    }

    function test_setFee_frozenForCurrentBlock() public {
        vm.prank(keeperAddr);
        plugin.setFee(8000);

        // Same block: quote and fill are still the old fee.
        assertEq(plugin.feeFor(), INITIAL_FEE);
        assertEq(_swapFee(), INITIAL_FEE);

        // Next block: new fee applies.
        vm.roll(block.number + 1);
        assertEq(plugin.feeFor(), 8000);
        assertEq(_swapFee(), 8000);
    }

    function test_setFee_multipleWritesSameBlock_lastWins() public {
        vm.startPrank(keeperAddr);
        plugin.setFee(8000);
        plugin.setFee(1000);
        vm.stopPrank();

        assertEq(_swapFee(), INITIAL_FEE);
        vm.roll(block.number + 1);
        assertEq(_swapFee(), 1000);
    }

    function test_setFee_acrossBlocks() public {
        vm.prank(keeperAddr);
        plugin.setFee(8000);
        vm.roll(block.number + 5);

        vm.prank(keeperAddr);
        plugin.setFee(600);
        assertEq(_swapFee(), 8000); // previous write is live, new one pending
        vm.roll(block.number + 1);
        assertEq(_swapFee(), 600);
    }

    function test_higherFee_lowerOutput() public {
        (, uint256 outLow) = _swap(pool, true, 1e18);
        _swap(pool, false, 1e18); // swap back so both trades start from about the same price

        vm.prank(keeperAddr);
        plugin.setFee(MAX_FEE);
        vm.roll(block.number + 1);
        (uint24 fee, uint256 outHigh) = _swap(pool, true, 1e18);

        assertEq(fee, MAX_FEE);
        assertLt(outHigh, outLow, "the pool must charge the override fee, not just report it");
    }

    function test_attachToInitializedPool() public {
        (IAlgebraPool p, KeeperFeePlugin pl) = _newPool(false);
        p.mint(address(this), address(this), -6000, 6000, 1e24, "");

        vm.prank(keeperAddr);
        pl.setFee(7000);
        vm.roll(block.number + 1);
        (uint24 fee,) = _swap(p, false, 1e15);
        assertEq(fee, 7000);
        assertEq(pl.feeFor(), fee);
    }

    function test_revert_notKeeper() public {
        vm.expectRevert(KeeperFeePlugin.NotKeeper.selector);
        plugin.setFee(4000);
    }

    function test_revert_feeOutOfBounds() public {
        vm.startPrank(keeperAddr);
        vm.expectRevert(abi.encodeWithSelector(KeeperFeePlugin.FeeOutOfBounds.selector, MAX_FEE + 1, MIN_FEE, MAX_FEE));
        plugin.setFee(MAX_FEE + 1);
        vm.expectRevert(abi.encodeWithSelector(KeeperFeePlugin.FeeOutOfBounds.selector, MIN_FEE - 1, MIN_FEE, MAX_FEE));
        plugin.setFee(MIN_FEE - 1);
        vm.stopPrank();
    }

    function test_revert_directHookCall() public {
        vm.expectRevert(KeeperFeePlugin.NotPool.selector);
        plugin.beforeSwap(address(this), address(this), true, 1, 0, false, "");
    }

    function test_tighterBounds_clampLiveFee() public {
        vm.prank(keeperAddr);
        plugin.setFee(9000);
        vm.roll(block.number + 1);

        pluginFactory.setBounds(MIN_FEE, 5000, INITIAL_FEE);
        assertEq(plugin.feeFor(), 5000);
        assertEq(_swapFee(), 5000);
    }

    function test_factory_onlyOwner() public {
        vm.startPrank(keeperAddr);
        vm.expectRevert(KeeperFeePluginFactory.NotOwner.selector);
        pluginFactory.setKeeper(keeperAddr);
        vm.expectRevert(KeeperFeePluginFactory.NotOwner.selector);
        pluginFactory.setBounds(MIN_FEE, 1000, 500);
        vm.expectRevert(KeeperFeePluginFactory.NotOwner.selector);
        pluginFactory.createPlugin(address(0xBEEF));
        vm.stopPrank();
    }

    function test_factory_rejectsZeroMinAndDuplicatePlugin() public {
        // overrideFee == 0 means "no override" to Algebra, so a zero fee must be impossible.
        vm.expectRevert(KeeperFeePluginFactory.InvalidBounds.selector);
        pluginFactory.setBounds(0, MAX_FEE, INITIAL_FEE);

        vm.expectRevert(
            abi.encodeWithSelector(KeeperFeePluginFactory.PluginExists.selector, address(pool), address(plugin))
        );
        pluginFactory.createPlugin(address(pool));
    }

    function testFuzz_quoteEqualsFill(uint24 fee, uint8 blocksLater, bool zeroToOne) public {
        fee = uint24(bound(fee, MIN_FEE, MAX_FEE));
        vm.prank(keeperAddr);
        plugin.setFee(fee);
        vm.roll(block.number + blocksLater);

        uint24 quoted = plugin.feeFor();
        assertEq(quoted, blocksLater == 0 ? INITIAL_FEE : fee);
        (uint24 charged,) = _swap(pool, zeroToOne, 1e15);
        assertEq(charged, quoted);
    }
}
