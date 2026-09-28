// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {VolFeeHook} from "../src/VolFeeHook.sol";

/// Local Anvil stack: PoolManager, two tokens, routers, VolFeeHook, one dynamic-fee pool with liquidity.
/// KEEPER (default: anvil account #1) is a separate signer from the broadcaster so their nonces never race.
/// Writes contracts/deployments/<chainId>.json.
///
/// forge script script/DevLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL_PK
contract DevLocal is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    VolFeeHook hook;
    address keeper;
    PoolKey key;

    function run() external {
        keeper = vm.envOr("KEEPER", 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        vm.startBroadcast();
        address me = msg.sender;

        manager = new PoolManager(me);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        (MockERC20 t0, MockERC20 t1) = _deployTokens(me);

        bytes memory args = abi.encode(manager, me, keeper, uint24(500), uint24(10_000), uint24(3000));
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(VolFeeHook).creationCode, args);
        hook = new VolFeeHook{salt: salt}(manager, me, keeper, 500, 10_000, 3000);

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e24, salt: 0}), ""
        );
        vm.stopBroadcast();

        _writeDeployment();
        console.log("hook   ", address(hook));
        console.log("keeper ", keeper);
        console.log("poolId ");
        console.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _deployTokens(address to) internal returns (MockERC20 t0, MockERC20 t1) {
        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = i == 0 ? t0 : t1;
            t.mint(to, 1e30);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(lpRouter), type(uint256).max);
        }
    }

    function _writeDeployment() internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "poolManager", address(manager));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "keeper", keeper);
        vm.serializeAddress(o, "swapRouter", address(swapRouter));
        vm.serializeAddress(o, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(o, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(o, "tickSpacing", uint256(uint24(TICK_SPACING)));
        string memory json = vm.serializeBytes32(o, "poolId", PoolId.unwrap(key.toId()));
        vm.writeJson(json, _deploymentPath());
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
    }
}
