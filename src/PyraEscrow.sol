// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPyraVaultFactory, IPyraVault} from "./interfaces/IPyra.sol";

/// @title PyraEscrow
/// @notice Funded jobs. Money leaves only along one of: release, refund, or a dispute ruling.
///         A job keeps the roles that were in force when it was funded, so a later role change
///         cannot reach money already in escrow.
contract PyraEscrow is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Assigned,
        Submitted,
        Disputed,
        Released,
        Refunded,
        Resolved
    }

    struct Job {
        address client;
        address worker;
        uint128 amount;
        uint64 deadline;
        uint64 submittedAt;
        uint32 reviewPeriod;
        Status status;
        bool verified;
        bytes32 specHash;
        bytes32 evidenceHash;
    }

    struct Roles {
        address coordinator;
        address verifier;
        address arbiter;
    }

    uint64 public constant ROLE_DELAY = 2 days;
    uint32 public constant MIN_REVIEW = 1 hours;
    uint32 public constant MAX_REVIEW = 14 days;
    uint64 public constant ARBITER_TIMEOUT = 30 days;

    IERC20 public immutable asset;
    IPyraVaultFactory public immutable factory;
    Roles public roles;
    Roles public pendingRoles;
    uint64 public rolesEffectiveAt;

    mapping(bytes32 => Job) public jobs;
    mapping(bytes32 => Roles) public jobRoles;

    event JobCreated(
        bytes32 indexed jobId,
        address indexed client,
        uint256 amount,
        uint64 deadline,
        uint32 reviewPeriod,
        bytes32 specHash
    );
    event JobAssigned(bytes32 indexed jobId, address indexed worker);
    event JobSubmitted(bytes32 indexed jobId, bytes32 evidenceHash);
    event JobAttested(bytes32 indexed jobId, bool passed, bytes32 reportHash);
    event JobReleased(bytes32 indexed jobId, address indexed worker, uint256 amount);
    event JobRefunded(bytes32 indexed jobId, address indexed client, uint256 amount);
    event JobDisputed(bytes32 indexed jobId);
    event JobResolved(bytes32 indexed jobId, uint256 workerAmount, uint256 clientAmount);
    event RolesProposed(address coordinator, address verifier, address arbiter, uint64 effectiveAt);
    event RolesChanged(address coordinator, address verifier, address arbiter);

    error Unauthorized();
    error BadState();
    error BadParams();
    error JobExists();
    error SelfDealing();

    constructor(
        address asset_,
        address factory_,
        address admin,
        address coordinator_,
        address verifier_,
        address arbiter_
    ) Ownable(admin) {
        asset = IERC20(asset_);
        factory = IPyraVaultFactory(factory_);
        _checkRoles(coordinator_, verifier_, arbiter_, admin);
        roles = Roles(coordinator_, verifier_, arbiter_);
        emit RolesChanged(coordinator_, verifier_, arbiter_);
    }

    /// @notice Role changes are public for two days before they apply, and only to jobs funded afterwards.
    function proposeRoles(address c, address v, address a) external onlyOwner {
        _checkRoles(c, v, a, owner());
        pendingRoles = Roles(c, v, a);
        rolesEffectiveAt = uint64(block.timestamp) + ROLE_DELAY;
        emit RolesProposed(c, v, a, rolesEffectiveAt);
    }

    function applyRoles() external {
        if (rolesEffectiveAt == 0 || block.timestamp < rolesEffectiveAt) revert BadState();
        Roles memory r = pendingRoles;
        _checkRoles(r.coordinator, r.verifier, r.arbiter, owner());
        roles = r;
        delete pendingRoles;
        rolesEffectiveAt = 0;
        emit RolesChanged(r.coordinator, r.verifier, r.arbiter);
    }

    /// @dev Three different keys, none of them the admin.
    function _checkRoles(address c, address v, address a, address admin) internal pure {
        if (c == address(0) || v == address(0) || a == address(0)) revert BadParams();
        if (c == v || c == a || v == a || c == admin || v == admin || a == admin) revert BadParams();
    }

    function jobIdOf(address client, bytes32 key) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), client, key));
    }

    function createJob(bytes32 key, uint128 amount, uint64 deadline, uint32 reviewPeriod, bytes32 specHash)
        external
        nonReentrant
        returns (bytes32 jobId)
    {
        if (
            amount == 0 || deadline <= block.timestamp || deadline > block.timestamp + 180 days
                || reviewPeriod < MIN_REVIEW || reviewPeriod > MAX_REVIEW || specHash == bytes32(0)
        ) revert BadParams();
        jobId = jobIdOf(msg.sender, key);
        if (jobs[jobId].status != Status.None) revert JobExists();
        jobs[jobId] =
            Job(msg.sender, address(0), amount, deadline, 0, reviewPeriod, Status.Open, false, specHash, bytes32(0));
        jobRoles[jobId] = roles;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit JobCreated(jobId, msg.sender, amount, deadline, reviewPeriod, specHash);
    }

    /// @notice Assigns a registered vault. Reverts when worker and client share an owner.
    function assign(bytes32 jobId, address worker) external {
        Job storage j = jobs[jobId];
        if (msg.sender != jobRoles[jobId].coordinator && msg.sender != j.client) revert Unauthorized();
        if (j.status != Status.Open || block.timestamp >= j.deadline) revert BadState();
        if (!factory.isVault(worker)) revert BadParams();
        if (_ultimateOwner(worker) == _ultimateOwner(j.client)) revert SelfDealing();
        j.worker = worker;
        j.status = Status.Assigned;
        emit JobAssigned(jobId, worker);
    }

    function submit(bytes32 jobId, bytes32 evidenceHash) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Assigned || block.timestamp >= j.deadline || evidenceHash == bytes32(0)) {
            revert BadState();
        }
        if (msg.sender != jobRoles[jobId].coordinator && msg.sender != _ultimateOwner(j.worker)) {
            revert Unauthorized();
        }
        j.evidenceHash = evidenceHash;
        j.submittedAt = uint64(block.timestamp);
        j.status = Status.Submitted;
        emit JobSubmitted(jobId, evidenceHash);
    }

    /// @notice A failed attestation reopens the job for another attempt before the deadline.
    function attest(bytes32 jobId, bool passed, bytes32 reportHash) external {
        if (msg.sender != jobRoles[jobId].verifier) revert Unauthorized();
        Job storage j = jobs[jobId];
        if (j.status != Status.Submitted || j.verified) revert BadState();
        if (passed) {
            j.verified = true;
            j.submittedAt = uint64(block.timestamp); // clients review verified work, so the window starts here
        } else {
            j.status = Status.Assigned;
            j.submittedAt = 0;
        }
        emit JobAttested(jobId, passed, reportHash);
    }

    /// @notice Client at any time after submission, or anyone once verified work clears review.
    function release(bytes32 jobId) external nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Submitted) revert BadState();
        if (msg.sender != j.client && (!j.verified || block.timestamp < j.submittedAt + j.reviewPeriod)) {
            revert Unauthorized();
        }
        j.status = Status.Released;
        asset.safeTransfer(j.worker, j.amount);
        emit JobReleased(jobId, j.worker, j.amount);
    }

    function dispute(bytes32 jobId) external {
        Job storage j = jobs[jobId];
        if (msg.sender != j.client) revert Unauthorized();
        if (j.status != Status.Submitted || !j.verified || block.timestamp >= j.submittedAt + j.reviewPeriod) {
            revert BadState();
        }
        j.status = Status.Disputed;
        j.submittedAt = uint64(block.timestamp);
        emit JobDisputed(jobId);
    }

    function resolve(bytes32 jobId, uint128 workerAmount) external nonReentrant {
        if (msg.sender != jobRoles[jobId].arbiter) revert Unauthorized();
        Job storage j = jobs[jobId];
        if (j.status != Status.Disputed || workerAmount > j.amount) revert BadState();
        j.status = Status.Resolved;
        uint256 back = j.amount - workerAmount;
        if (workerAmount > 0) asset.safeTransfer(j.worker, workerAmount);
        if (back > 0) asset.safeTransfer(j.client, back);
        emit JobResolved(jobId, workerAmount, back);
    }

    function cancel(bytes32 jobId) external nonReentrant {
        Job storage j = jobs[jobId];
        if (msg.sender != j.client) revert Unauthorized();
        if (j.status != Status.Open) revert BadState();
        _refund(jobId, j);
    }

    /// @notice Permissionless once a job can no longer succeed, so funds never get stuck.
    function refundExpired(bytes32 jobId) external nonReentrant {
        Job storage j = jobs[jobId];
        bool open = (j.status == Status.Open || j.status == Status.Assigned) && block.timestamp >= j.deadline;
        bool unverified =
            j.status == Status.Submitted && !j.verified && block.timestamp >= uint256(j.deadline) + j.reviewPeriod;
        bool abandoned = j.status == Status.Disputed && block.timestamp >= j.submittedAt + ARBITER_TIMEOUT;
        if (!open && !unverified && !abandoned) revert BadState();
        _refund(jobId, j);
    }

    function _refund(bytes32 jobId, Job storage j) internal {
        j.status = Status.Refunded;
        asset.safeTransfer(j.client, j.amount);
        emit JobRefunded(jobId, j.client, j.amount);
    }

    function _ultimateOwner(address a) internal view returns (address) {
        return factory.isVault(a) ? IPyraVault(a).owner() : a;
    }
}
