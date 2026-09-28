// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {VolFeeHook} from "../src/VolFeeHook.sol";

contract VolFeeHookTest is Test, Deployers {
    uint24 constant MIN_FEE = 500; // 5 bp
    uint24 constant MAX_FEE = 10_000; // 100 bp
    uint24 constant INITIAL_FEE = 3000; // 30 bp

    address keeperAddr = makeAddr("keeper");
    VolFeeHook hook;
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) | (0x4444 << 144));
        deployCodeTo(
            "VolFeeHook.sol:VolFeeHook",
            abi.encode(manager, address(this), keeperAddr, MIN_FEE, MAX_FEE, INITIAL_FEE),
            hookAddr
        );
        hook = VolFeeHook(hookAddr);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(hookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        id = key.toId();
    }

    /// Swap and return the fee the PoolManager actually charged (from its Swap event).
    function _swapFee() internal returns (uint24) {
        vm.recordLogs();
        swap(key, true, -1e15, ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapSig = IPoolManager.Swap.selector;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == swapSig) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    function test_initialFee_quoteEqualsFill() public {
        uint24 quoted = hook.feeFor(id);
        assertEq(quoted, INITIAL_FEE);
        assertEq(_swapFee(), quoted);
    }

    function test_setFee_frozenForCurrentBlock() public {
        vm.prank(keeperAddr);
        hook.setFee(id, 8000);

        // Same block: quote and fill are still the old fee.
        assertEq(hook.feeFor(id), INITIAL_FEE);
        assertEq(_swapFee(), INITIAL_FEE);

        // Next block: new fee applies.
        vm.roll(block.number + 1);
        assertEq(hook.feeFor(id), 8000);
        assertEq(_swapFee(), 8000);
    }

    function test_setFee_multipleWritesSameBlock_lastWins() public {
        vm.startPrank(keeperAddr);
        hook.setFee(id, 8000);
        hook.setFee(id, 1000);
        vm.stopPrank();

        assertEq(_swapFee(), INITIAL_FEE);
        vm.roll(block.number + 1);
        assertEq(_swapFee(), 1000);
    }

    function test_setFee_acrossBlocks() public {
        vm.prank(keeperAddr);
        hook.setFee(id, 8000);
        vm.roll(block.number + 5);

        vm.prank(keeperAddr);
        hook.setFee(id, 600);
        assertEq(_swapFee(), 8000); // previous write is live, new one pending
        vm.roll(block.number + 1);
        assertEq(_swapFee(), 600);
    }

    function test_revert_notKeeper() public {
        vm.expectRevert(VolFeeHook.NotKeeper.selector);
        hook.setFee(id, 4000);
    }

    function test_revert_feeOutOfBounds() public {
        vm.startPrank(keeperAddr);
        vm.expectRevert(abi.encodeWithSelector(VolFeeHook.FeeOutOfBounds.selector, MAX_FEE + 1, MIN_FEE, MAX_FEE));
        hook.setFee(id, MAX_FEE + 1);
        vm.expectRevert(abi.encodeWithSelector(VolFeeHook.FeeOutOfBounds.selector, MIN_FEE - 1, MIN_FEE, MAX_FEE));
        hook.setFee(id, MIN_FEE - 1);
        vm.stopPrank();
    }

    function test_revert_unknownPool() public {
        PoolId other = PoolId.wrap(bytes32(uint256(1)));
        vm.prank(keeperAddr);
        vm.expectRevert(VolFeeHook.PoolNotInitialized.selector);
        hook.setFee(other, 4000);
    }

    function test_revert_staticFeePool() public {
        vm.expectRevert(); // wrapped by PoolManager
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_revert_directHookCall() public {
        vm.expectRevert(VolFeeHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_tighterBounds_clampLiveFee() public {
        vm.prank(keeperAddr);
        hook.setFee(id, 9000);
        vm.roll(block.number + 1);

        hook.setBounds(MIN_FEE, 5000, INITIAL_FEE);
        assertEq(hook.feeFor(id), 5000);
        assertEq(_swapFee(), 5000);
    }

    function test_admin_onlyOwner() public {
        vm.startPrank(keeperAddr);
        vm.expectRevert(VolFeeHook.NotOwner.selector);
        hook.setKeeper(keeperAddr);
        vm.expectRevert(VolFeeHook.NotOwner.selector);
        hook.setBounds(0, 1000, 500);
        vm.stopPrank();
    }

    function testFuzz_quoteEqualsFill(uint24 fee, uint8 blocksLater) public {
        fee = uint24(bound(fee, MIN_FEE, MAX_FEE));
        vm.prank(keeperAddr);
        hook.setFee(id, fee);
        vm.roll(block.number + blocksLater);

        uint24 quoted = hook.feeFor(id);
        assertEq(quoted, blocksLater == 0 ? INITIAL_FEE : fee);
        assertEq(_swapFee(), quoted);
    }
}
