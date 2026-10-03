// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {IAlgebraPool} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import {DevAlgebraRouter} from "./DevAlgebraRouter.sol";

/// One exact-input swap against the DevLocalAlgebra pool. Check the charged fee with
/// `KEEPER_TARGET=algebra pnpm fills` (Forge scripts only see their simulation, not the receipt).
///
/// ZERO_FOR_ONE=true AMOUNT=1000000000000000000 \
///   forge script script/DevSwapAlgebra.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL_PK
contract DevSwapAlgebra is Script {
    function run() external {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".algebra.json")
        );
        DevAlgebraRouter router = DevAlgebraRouter(vm.parseJsonAddress(json, ".router"));
        IAlgebraPool pool = IAlgebraPool(vm.parseJsonAddress(json, ".pool"));

        vm.startBroadcast();
        router.swap(pool, vm.envOr("ZERO_FOR_ONE", true), vm.envOr("AMOUNT", uint256(1e18)));
        vm.stopBroadcast();
    }
}
