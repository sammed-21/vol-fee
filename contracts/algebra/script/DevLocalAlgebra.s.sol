// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AlgebraFactory} from "@cryptoalgebra/integral-core/contracts/AlgebraFactory.sol";
import {AlgebraPoolDeployer} from "@cryptoalgebra/integral-core/contracts/AlgebraPoolDeployer.sol";
import {IAlgebraPool} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";

import {KeeperFeePlugin} from "../src/KeeperFeePlugin.sol";
import {KeeperFeePluginFactory} from "../src/KeeperFeePluginFactory.sol";
import {DevAlgebraRouter, DevToken} from "./DevAlgebraRouter.sol";

/// Local Anvil stack on real Algebra Integral v1.2.2: factory, pool, KeeperFeePlugin, liquidity.
/// KEEPER (default: anvil account #1) signs fee writes. Writes ../deployments/<chainId>.algebra.json.
///
/// forge script script/DevLocalAlgebra.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///   --private-key $ANVIL_PK --disable-code-size-limit
contract DevLocalAlgebra is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    AlgebraFactory algebraFactory;
    KeeperFeePluginFactory pluginFactory;
    DevAlgebraRouter router;
    IAlgebraPool pool;
    KeeperFeePlugin plugin;
    address keeper;

    function run() external {
        keeper = vm.envOr("KEEPER", 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        vm.startBroadcast();
        address me = msg.sender;

        // AlgebraPoolDeployer and AlgebraFactory reference each other: precompute the factory address.
        address factoryAddr = vm.computeCreateAddress(me, vm.getNonce(me) + 1);
        AlgebraPoolDeployer poolDeployer = new AlgebraPoolDeployer(factoryAddr);
        algebraFactory = new AlgebraFactory(address(poolDeployer));
        require(address(algebraFactory) == factoryAddr, "factory address mismatch");

        router = new DevAlgebraRouter();
        (DevToken t0, DevToken t1) = _deployTokens(me);

        pluginFactory = new KeeperFeePluginFactory(me, keeper, 500, 10_000, 3000);
        pool = IAlgebraPool(algebraFactory.createPool(address(t0), address(t1), ""));
        plugin = KeeperFeePlugin(pluginFactory.createPlugin(address(pool)));
        pool.setPlugin(address(plugin)); // me = factory owner = pool administrator
        pool.initialize(SQRT_PRICE_1_1); // plugin turns on BEFORE_SWAP + DYNAMIC_FEE
        router.mint(pool, -6000, 6000, 1e24);
        vm.stopBroadcast();

        _writeDeployment();
        console.log("pool   ", address(pool));
        console.log("plugin ", address(plugin));
        console.log("keeper ", keeper);
    }

    function _deployTokens(address to) internal returns (DevToken t0, DevToken t1) {
        DevToken a = new DevToken("A");
        DevToken b = new DevToken("B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(to, 1e30);
        t1.mint(to, 1e30);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
    }

    function _writeDeployment() internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "kind", "algebra");
        vm.serializeAddress(o, "algebraFactory", address(algebraFactory));
        vm.serializeAddress(o, "pool", address(pool));
        vm.serializeAddress(o, "plugin", address(plugin));
        vm.serializeAddress(o, "pluginFactory", address(pluginFactory));
        vm.serializeAddress(o, "keeper", keeper);
        string memory json = vm.serializeAddress(o, "router", address(router));
        vm.writeJson(json, _deploymentPath());
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".algebra.json");
    }
}
