// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PyraPrizePoolAccelerated} from "../src/testnet/PyraPrizePoolAccelerated.sol";

interface IFactory {
    function asset() external view returns (address);
}

/// Deploys one contract: a prize pool with a short dispute window, beside the existing deployment and never in place of it.
/// It uses the existing vault factory, so existing vaults can win. It cannot run anywhere but Robinhood Chain testnet.
contract DeployAccelerated is Script {
    address constant USDG = 0x7E955252E15c84f5768B83c41a71F9eba181802F;

    function run() external {
        require(block.chainid == 46630, "Robinhood Chain testnet only");
        string memory live = vm.readFile(string.concat("./deployments/", vm.envOr("PYRA_BASE", string("46630")), ".json"));
        address factory = vm.parseJsonAddress(live, ".factory");
        require(IFactory(factory).asset() == USDG, "the factory is not the USDG one");
        address admin = vm.envAddress("PYRA_ADMIN");
        address coordinator = vm.envAddress("PYRA_COORDINATOR");
        address arbiter = vm.envAddress("PYRA_ARBITER");
        uint64 window = uint64(vm.envOr("DISPUTE_SECONDS", uint256(900)));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PyraPrizePoolAccelerated p = new PyraPrizePoolAccelerated(USDG, factory, admin, coordinator, arbiter, window);
        vm.stopBroadcast();

        require(p.DISPUTE_WINDOW() == window && address(p.asset()) == USDG && address(p.factory()) == factory, "check failed");
        console2.log("accelerated prize pool", address(p));
        console2.log("dispute window, seconds", p.DISPUTE_WINDOW());
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("dry run: nothing sent, no deployment file written");
            return;
        }
        // Its own file. The live deployment's file is only read.
        string memory o = "d";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", vm.envUint("START_BLOCK"));
        vm.serializeAddress(o, "asset", USDG);
        vm.serializeAddress(o, "factory", factory);
        vm.serializeAddress(o, "escrow", vm.parseJsonAddress(live, ".escrow"));
        vm.serializeAddress(o, "prizePool", address(p));
        vm.serializeUint(o, "disputeSeconds", window);
        string memory json = vm.serializeAddress(o, "swapAdapter", vm.parseJsonAddress(live, ".swapAdapter"));
        vm.writeJson(json, string.concat("./deployments/", vm.envOr("PYRA_DEPLOYMENT", string("46630-accelerated")), ".json"));
    }
}
