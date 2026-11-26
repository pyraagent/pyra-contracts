// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PyraVaultFactory} from "../src/PyraVaultFactory.sol";
import {PyraEscrow} from "../src/PyraEscrow.sol";
import {PyraPrizePool} from "../src/PyraPrizePool.sol";
import {UniV4Adapter, IStateView} from "../src/UniV4Adapter.sol";

/// Deploys to Robinhood Chain testnet (46630) or mainnet (4663). Any other chain id reverts.
/// Mainnet also needs PYRA_MAINNET_GO="deploy to 4663", and the admin and arbiter must be contracts (a Safe), not keys.
contract Deploy is Script {
    uint256 constant TESTNET = 46630;
    uint256 constant MAINNET = 4663;
    address constant USDG_TESTNET = 0x7E955252E15c84f5768B83c41a71F9eba181802F;
    address constant USDG_MAINNET = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    function run() external {
        require(block.chainid == TESTNET || block.chainid == MAINNET, "Robinhood Chain only");
        address USDG = block.chainid == MAINNET ? USDG_MAINNET : USDG_TESTNET;
        require(
            keccak256(bytes(IERC20Metadata(USDG).symbol())) == keccak256("USDG")
                && IERC20Metadata(USDG).decimals() == 6,
            "USDG check failed"
        );
        address admin = vm.envAddress("PYRA_ADMIN");
        address coordinator = vm.envAddress("PYRA_COORDINATOR");
        address verifier = vm.envAddress("PYRA_VERIFIER");
        address arbiter = vm.envAddress("PYRA_ARBITER");
        require(
            coordinator != verifier && arbiter != coordinator && arbiter != verifier && admin != coordinator
                && admin != verifier && admin != arbiter,
            "roles must differ"
        );
        if (block.chainid == MAINNET) {
            require(keccak256(bytes(vm.envOr("PYRA_MAINNET_GO", string("")))) == keccak256("deploy to 4663"), "mainnet needs PYRA_MAINNET_GO");
            // A Safe needing at least two signatures. Code alone is not proof: an EIP-7702 delegated key also has code.
            require(_isSafe(admin) && _isSafe(arbiter), "on mainnet the admin and arbiter must be Safes needing 2 or more signatures");
        }

        // Read from the environment so the key never appears in a process list.
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        PyraVaultFactory factory = new PyraVaultFactory(USDG);
        PyraEscrow escrow = new PyraEscrow(USDG, address(factory), admin, coordinator, verifier, arbiter);
        PyraPrizePool prizes = new PyraPrizePool(USDG, address(factory), admin, coordinator, arbiter);
        UniV4Adapter adapter = new UniV4Adapter(POOL_MANAGER, STATE_VIEW, address(0), USDG, 3000, 60);
        vm.stopBroadcast();

        (uint160 p,,,) = IStateView(STATE_VIEW).getSlot0(adapter.poolId());
        require(p > 0, "pool not initialised");

        console2.log("factory", address(factory));
        console2.log("escrow", address(escrow));
        console2.log("prizePool", address(prizes));
        console2.log("swapAdapter", address(adapter));
        // A dry run must never leave a file the API would read as a real deployment.
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("dry run: nothing sent, no deployment file written");
            return;
        }

        string memory o = "d";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", vm.envUint("START_BLOCK")); // block.number is the L1 number on Orbit chains
        vm.serializeAddress(o, "asset", USDG);
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "escrow", address(escrow));
        vm.serializeAddress(o, "prizePool", address(prizes));
        string memory json = vm.serializeAddress(o, "swapAdapter", address(adapter));
        vm.writeJson(json, string.concat("./deployments/", vm.envOr("PYRA_DEPLOYMENT", vm.toString(block.chainid)), ".json"));
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
