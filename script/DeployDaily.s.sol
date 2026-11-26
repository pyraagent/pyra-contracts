// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PyraDailyRewards} from "../src/testnet/PyraDailyRewards.sol";

interface IFactory {
    function asset() external view returns (address);
}

/// Deploys one contract: daily rewards, beside the existing deployment and never in place of it.
/// It uses the existing vault factory, so existing vaults can win. Robinhood Chain testnet or mainnet only.
/// Mainnet also needs PYRA_MAINNET_GO="deploy to 4663", and the admin and arbiter must be contracts (a Safe).
contract DeployDaily is Script {
    function run() external {
        require(block.chainid == 46630 || block.chainid == 4663, "Robinhood Chain only");
        address USDG = block.chainid == 4663 ? 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 : 0x7E955252E15c84f5768B83c41a71F9eba181802F;
        string memory live = vm.readFile(string.concat("./deployments/", vm.envOr("PYRA_BASE", vm.toString(block.chainid)), ".json"));
        address factory = vm.parseJsonAddress(live, ".factory");
        require(IFactory(factory).asset() == USDG, "the factory is not the USDG one");
        address admin = vm.envAddress("PYRA_ADMIN");
        address coordinator = vm.envAddress("PYRA_COORDINATOR");
        address arbiter = vm.envAddress("PYRA_ARBITER");
        uint64 review = uint64(vm.envOr("REVIEW_SECONDS", uint256(3600)));
        if (block.chainid == 4663) {
            require(keccak256(bytes(vm.envOr("PYRA_MAINNET_GO", string("")))) == keccak256("deploy to 4663"), "mainnet needs PYRA_MAINNET_GO");
            // A Safe needing at least two signatures. Code alone is not proof: an EIP-7702 delegated key also has code.
            require(_isSafe(admin) && _isSafe(arbiter), "on mainnet the admin and arbiter must be Safes needing 2 or more signatures");
        }

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PyraDailyRewards d = new PyraDailyRewards(USDG, factory, admin, coordinator, arbiter, review);
        vm.stopBroadcast();

        require(d.REVIEW() == review && address(d.asset()) == USDG && address(d.factory()) == factory, "check failed");
        console2.log("daily rewards", address(d));
        console2.log("review, seconds", d.REVIEW());
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("dry run: nothing sent, no deployment file written");
            return;
        }
        // Its own file. The live deployment's file is only read.
        string memory o = "d";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", vm.envUint("START_BLOCK"));
        vm.serializeAddress(o, "factory", factory);
        vm.serializeUint(o, "reviewSeconds", review);
        string memory json = vm.serializeAddress(o, "dailyRewards", address(d));
        vm.writeJson(json, string.concat("./deployments/", vm.envOr("PYRA_DEPLOYMENT", string.concat(vm.toString(block.chainid), "-daily")), ".json"));
    }

    function _isSafe(address a) internal view returns (bool) {
        if (a.code.length <= 23) return false; // 23 bytes is an EIP-7702 delegation, not a contract
        (bool ok, bytes memory r) = a.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (!ok || r.length != 32) return false;
        (bool ok2, bytes memory o) = a.staticcall(abi.encodeWithSignature("getOwners()"));
        if (!ok2) return false;
        uint256 threshold = abi.decode(r, (uint256));
        return threshold >= 2 && abi.decode(o, (address[])).length >= threshold;
    }
}
