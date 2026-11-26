// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PyraVault} from "./PyraVault.sol";

/// @title PyraVaultFactory
/// @notice Deploys one vault per agent. Caps live vaults at five per owner. No admin.
contract PyraVaultFactory {
    uint256 public constant MAX_ACTIVE = 5;
    address public immutable implementation;
    address public immutable asset;

    mapping(address => bool) public isVault;
    mapping(address => uint256) public activeCount;
    mapping(bytes32 => address) public vaultOf; // keccak(owner, agentId)

    event VaultCreated(address indexed owner, bytes32 indexed agentId, address vault);

    error TooManyAgents();
    error VaultExists();
    error NotVault();

    constructor(address asset_) {
        asset = asset_;
        implementation = address(new PyraVault());
    }

    function createVault(bytes32 agentId, PyraVault.Config calldata cfg) external returns (address vault) {
        if (activeCount[msg.sender] >= MAX_ACTIVE) revert TooManyAgents();
        bytes32 salt = keccak256(abi.encode(msg.sender, agentId));
        if (vaultOf[salt] != address(0)) revert VaultExists();
        vault = Clones.cloneDeterministic(implementation, salt);
        vaultOf[salt] = vault;
        isVault[vault] = true;
        activeCount[msg.sender]++;
        PyraVault(payable(vault)).initialize(msg.sender, asset, agentId, cfg);
        emit VaultCreated(msg.sender, agentId, vault);
    }

    /// @dev A vault can only retire once, so this can only run once per vault.
    function onRetired(address owner) external {
        if (!isVault[msg.sender]) revert NotVault();
        activeCount[owner]--;
    }

    function predict(address owner, bytes32 agentId) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, keccak256(abi.encode(owner, agentId)));
    }
}
