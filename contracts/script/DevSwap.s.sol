// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {VolFeeHook} from "../src/VolFeeHook.sol";

/// One exact-input swap against the DevLocal pool.
/// Forge scripts only see their local simulation, not the mined receipt, so this does not report the
/// charged fee. Check fills with `pnpm fills`, which reads the real Swap events.
///
/// ZERO_FOR_ONE=true AMOUNT=1000000000000000000 \
///   forge script script/DevSwap.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL_PK
contract DevSwap is Script {
    function run() external {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
        VolFeeHook hook = VolFeeHook(vm.parseJsonAddress(json, ".hook"));
        PoolSwapTest router = PoolSwapTest(vm.parseJsonAddress(json, ".swapRouter"));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(json, ".currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(json, ".currency1")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(int256(vm.parseJsonUint(json, ".tickSpacing"))),
            hooks: IHooks(address(hook))
        });
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        int256 amount = int256(vm.envOr("AMOUNT", uint256(1e18)));

        vm.startBroadcast();
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
    }
}
