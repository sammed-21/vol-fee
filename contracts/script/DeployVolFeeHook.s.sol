// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {VolFeeHook} from "../src/VolFeeHook.sol";

/// forge script script/DeployVolFeeHook.s.sol --rpc-url $RPC_URL --broadcast
/// Writes contracts/deployments/<chainId>.json (add poolId once the pool is initialized).
/// env: POOL_MANAGER, KEEPER, [MIN_FEE=500, MAX_FEE=10000, INITIAL_FEE=3000]  (pips; 100 = 1 bp)
contract DeployVolFeeHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address keeper = vm.envAddress("KEEPER");
        uint24 minFee = uint24(vm.envOr("MIN_FEE", uint256(500)));
        uint24 maxFee = uint24(vm.envOr("MAX_FEE", uint256(10_000)));
        uint24 initialFee = uint24(vm.envOr("INITIAL_FEE", uint256(3000)));

        vm.startBroadcast();
        address owner = msg.sender;
        bytes memory args = abi.encode(manager, owner, keeper, minFee, maxFee, initialFee);

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(VolFeeHook).creationCode, args);

        VolFeeHook hook = new VolFeeHook{salt: salt}(manager, owner, keeper, minFee, maxFee, initialFee);
        require(address(hook) == expected, "hook address mismatch");
        vm.stopBroadcast();

        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "poolManager", address(manager));
        string memory json = vm.serializeAddress(o, "hook", address(hook));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));

        console.log("VolFeeHook:", address(hook));
        console.log("Init pools with fee = 0x800000 (DYNAMIC_FEE_FLAG)");
    }
}
