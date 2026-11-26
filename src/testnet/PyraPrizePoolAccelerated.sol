// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPyraVaultFactory, IPyraVault} from "../interfaces/IPyra.sol";

/// @title PyraPrizePoolAccelerated
/// @notice TESTNET ONLY. PyraPrizePool with a shorter dispute window, for testing the reward lifecycle.
///         It cannot be deployed on any chain but Robinhood Chain testnet. Every other line is PyraPrizePool's,
///         and test/Accelerated.t.sol fails if that stops being true.
///         Sponsor-funded epochs. Top three vaults split 50/30/20 after a dispute window.
///         Prize money is never mixed with job escrow or vault capital. An epoch keeps the roles it
///         opened with, so a later role change cannot redirect prizes already funded.
contract PyraPrizePoolAccelerated is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Proposed,
        Finalized,
        Cancelled
    }

    struct Epoch {
        uint64 start;
        uint64 end;
        uint64 finalizableAt;
        Status status;
        bool flagged;
        uint128 pool;
        uint128 rolledIn;
        bytes32 rulesHash;
        bytes32 scoreRoot;
        address[3] winners;
        bool[3] claimed;
    }

    struct Roles {
        address scorer;
        address arbiter;
    }

    uint64 public constant ROLE_DELAY = 2 days;
    uint64 public immutable DISPUTE_WINDOW;
    uint64 public constant MIN_WINDOW = 15 minutes;
    uint64 public constant MAX_WINDOW = 2 days;
    uint256 public constant TESTNET = 46630;
    uint64 public constant PROPOSAL_TIMEOUT = 30 days;

    IERC20 public immutable asset;
    IPyraVaultFactory public immutable factory;
    Roles public roles;
    Roles public pendingRoles;
    uint64 public rolesEffectiveAt;
    uint256 public epochCount;
    uint128 public rollover;

    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => Roles) public epochRoles;
    mapping(uint256 => mapping(address => uint128)) public contributed;

    event EpochCreated(uint256 indexed epochId, uint64 start, uint64 end, bytes32 rulesHash, uint256 rolledIn);
    event EpochFunded(uint256 indexed epochId, address indexed sponsor, uint256 amount);
    event ResultProposed(uint256 indexed epochId, address[3] winners, bytes32 scoreRoot, uint64 finalizableAt);
    event ResultFlagged(uint256 indexed epochId, address indexed by, bytes32 evidenceHash, uint64 finalizableAt);
    event ResultRejected(uint256 indexed epochId, bytes32 reasonHash);
    event EpochFinalized(uint256 indexed epochId, uint256 rolledOut);
    event EpochCancelled(uint256 indexed epochId);
    event PrizeClaimed(uint256 indexed epochId, uint8 indexed rank, address indexed vault, uint256 amount);
    event Reclaimed(uint256 indexed epochId, address indexed sponsor, uint256 amount);
    event RolesProposed(address scorer, address arbiter, uint64 effectiveAt);
    event RolesChanged(address scorer, address arbiter);

    error Unauthorized();
    error BadState();
    error BadParams();
    error TestnetOnly();

    constructor(address asset_, address factory_, address admin, address scorer_, address arbiter_, uint64 window_)
        Ownable(admin)
    {
        if (block.chainid != TESTNET) revert TestnetOnly();
        if (window_ < MIN_WINDOW || window_ > MAX_WINDOW) revert BadParams();
        DISPUTE_WINDOW = window_;
        asset = IERC20(asset_);
        factory = IPyraVaultFactory(factory_);
        _checkRoles(scorer_, arbiter_, admin);
        roles = Roles(scorer_, arbiter_);
        emit RolesChanged(scorer_, arbiter_);
    }

    /// @notice Role changes are public for two days before they apply, and only to later epochs.
    function proposeRoles(address s, address a) external onlyOwner {
        _checkRoles(s, a, owner());
        pendingRoles = Roles(s, a);
        rolesEffectiveAt = uint64(block.timestamp) + ROLE_DELAY;
        emit RolesProposed(s, a, rolesEffectiveAt);
    }

    function applyRoles() external {
        if (rolesEffectiveAt == 0 || block.timestamp < rolesEffectiveAt) revert BadState();
        Roles memory r = pendingRoles;
        _checkRoles(r.scorer, r.arbiter, owner());
        roles = r;
        delete pendingRoles;
        rolesEffectiveAt = 0;
        emit RolesChanged(r.scorer, r.arbiter);
    }

    function _checkRoles(address s, address a, address admin) internal pure {
        if (s == address(0) || a == address(0) || s == a || s == admin || a == admin) revert BadParams();
    }

    function epoch(uint256 id) external view returns (Epoch memory) {
        return _epochs[id];
    }

    function createEpoch(uint64 start, uint64 end, bytes32 rulesHash) external returns (uint256 id) {
        if (msg.sender != roles.scorer) revert Unauthorized();
        if (end <= start || end <= block.timestamp || rulesHash == bytes32(0)) revert BadParams();
        id = ++epochCount;
        epochRoles[id] = roles;
        Epoch storage e = _epochs[id];
        e.start = start;
        e.end = end;
        e.rulesHash = rulesHash;
        e.status = Status.Open;
        uint128 carried = rollover;
        e.pool = carried;
        e.rolledIn = carried;
        rollover = 0;
        emit EpochCreated(id, start, end, rulesHash, carried);
    }

    function fund(uint256 id, uint128 amount) external nonReentrant {
        Epoch storage e = _epochs[id];
        if (e.status != Status.Open || block.timestamp >= e.end || amount == 0) revert BadState();
        e.pool += amount;
        contributed[id][msg.sender] += amount;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit EpochFunded(id, msg.sender, amount);
    }

    /// @notice Winners may include trailing zero addresses; one prize per ultimate owner.
    function propose(uint256 id, address[3] calldata winners, bytes32 scoreRoot) external {
        if (msg.sender != epochRoles[id].scorer) revert Unauthorized();
        Epoch storage e = _epochs[id];
        if (e.status != Status.Open || block.timestamp < e.end || scoreRoot == bytes32(0)) revert BadState();
        for (uint256 i; i < 3; ++i) {
            if (winners[i] == address(0)) {
                if (i < 2 && winners[i + 1] != address(0)) revert BadParams();
                continue;
            }
            if (!factory.isVault(winners[i])) revert BadParams();
            for (uint256 k; k < i; ++k) {
                if (IPyraVault(winners[k]).owner() == IPyraVault(winners[i]).owner()) revert BadParams();
            }
        }
        e.winners = winners;
        e.scoreRoot = scoreRoot;
        e.status = Status.Proposed;
        e.finalizableAt = uint64(block.timestamp) + DISPUTE_WINDOW;
        emit ResultProposed(id, winners, scoreRoot, e.finalizableAt);
    }

    /// @notice Any vault owner can extend the window once per proposal while the arbiter looks.
    function flag(uint256 id, address vault, bytes32 evidenceHash) external {
        Epoch storage e = _epochs[id];
        if (!factory.isVault(vault) || IPyraVault(vault).owner() != msg.sender) revert Unauthorized();
        if (e.status != Status.Proposed || e.flagged || block.timestamp >= e.finalizableAt) revert BadState();
        e.flagged = true;
        e.finalizableAt = uint64(block.timestamp) + DISPUTE_WINDOW;
        emit ResultFlagged(id, msg.sender, evidenceHash, e.finalizableAt);
    }

    function reject(uint256 id, bytes32 reasonHash) external {
        if (msg.sender != epochRoles[id].arbiter) revert Unauthorized();
        Epoch storage e = _epochs[id];
        if (e.status != Status.Proposed || block.timestamp >= e.finalizableAt) revert BadState();
        e.status = Status.Open;
        e.flagged = false;
        delete e.winners;
        emit ResultRejected(id, reasonHash);
    }

    function finalize(uint256 id) external {
        Epoch storage e = _epochs[id];
        if (e.status != Status.Proposed || block.timestamp < e.finalizableAt) revert BadState();
        e.status = Status.Finalized;
        uint128 out;
        for (uint8 i; i < 3; ++i) {
            if (e.winners[i] == address(0)) out += _share(e.pool, i);
        }
        rollover += out;
        emit EpochFinalized(id, out);
    }

    function claim(uint256 id, uint8 rank) external nonReentrant {
        Epoch storage e = _epochs[id];
        if (rank > 2 || e.status != Status.Finalized || e.claimed[rank] || e.winners[rank] == address(0)) {
            revert BadState();
        }
        e.claimed[rank] = true;
        uint128 amount = _share(e.pool, rank);
        asset.safeTransfer(e.winners[rank], amount);
        emit PrizeClaimed(id, rank, e.winners[rank], amount);
    }

    /// @notice If no result is ever proposed, sponsors take their money back.
    function cancelStale(uint256 id) external {
        Epoch storage e = _epochs[id];
        if (e.status != Status.Open || block.timestamp < uint256(e.end) + PROPOSAL_TIMEOUT) revert BadState();
        e.status = Status.Cancelled;
        rollover += e.rolledIn; // carried money has no sponsor to return to
        emit EpochCancelled(id);
    }

    function reclaim(uint256 id) external nonReentrant {
        if (_epochs[id].status != Status.Cancelled) revert BadState();
        uint128 amount = contributed[id][msg.sender];
        if (amount == 0) revert BadState();
        contributed[id][msg.sender] = 0;
        asset.safeTransfer(msg.sender, amount);
        emit Reclaimed(id, msg.sender, amount);
    }

    /// @dev 50/30/20. Rounding dust goes to first place.
    function _share(uint128 pool, uint8 rank) internal pure returns (uint128) {
        uint128 second = pool * 30 / 100;
        uint128 third = pool * 20 / 100;
        if (rank == 1) return second;
        if (rank == 2) return third;
        return pool - second - third;
    }
}
