// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPyraVaultFactory, IPyraVault} from "../interfaces/IPyra.sol";

/// @title PyraDailyRewards
/// @notice Robinhood Chain testnet (46630) and mainnet (4663) only. A sponsor-funded prize for every UTC day, paid straight to the top three vaults, 50/30/20.
///         A day is block.timestamp / 1 days, so nobody opens one, closes one or moves its edge. Every day stands alone:
///         one that is late, disputed or void holds up no other, and its money is never used for another.
///         Nobody claims. Once the review time is over, one call from anyone pays all three.
///         What nobody wins goes back to the sponsors who gave it, in proportion. No role can send it anywhere else.
contract PyraDailyRewards is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Posted,
        Paid,
        Void
    }

    struct Day {
        uint128 pool; // everything given for the day
        uint128 refundable; // the part of it nobody won
        uint64 reviewEnds;
        uint64 payableAt;
        Status status;
        bool flagged;
        uint8 rejections;
        uint8 settled; // one bit per rank: paid, or given back
        address[3] winners;
        bytes32 root; // keccak256 of the published record the winners came from
    }

    struct Roles {
        address scorer;
        address arbiter;
    }

    uint256 public constant TESTNET = 46630;
    uint256 public constant MAINNET = 4663;
    /// @notice The most one day can hold, so a stolen scorer key can never reach more than this in a day.
    uint128 public constant MAX_POOL = 100e6;
    uint256 public constant MAX_REJECTIONS = 2;
    uint64 public constant MIN_REVIEW = 15 minutes;
    uint64 public constant MAX_REVIEW = 6 hours;
    /// @notice How long after midnight a result may be posted. Past it the day is void and the sponsors are repaid.
    uint64 public constant POST_WINDOW = 36 hours;
    /// @notice How long one objection can hold a payment, at most, if the arbiter says nothing.
    uint64 public constant FLAG_HOLD = 12 hours;
    /// @notice A prize a vault cannot receive is tried for this long, then goes back to the sponsors.
    uint64 public constant RETRY_FOR = 30 days;
    /// @notice Longer than a day already running takes to be payable, so a new role never decides a day that was already promised.
    uint64 public constant ROLE_DELAY = 4 days;

    uint64 public immutable REVIEW;
    IERC20 public immutable asset;
    IPyraVaultFactory public immutable factory;
    Roles public roles;
    Roles public pendingRoles;
    uint64 public rolesEffectiveAt;

    mapping(uint256 => Day) internal _days;
    mapping(uint256 => mapping(address => uint128)) public given;
    mapping(uint256 => mapping(address => uint128)) public refunded;

    event DayFunded(uint256 indexed day, address indexed sponsor, uint256 amount);
    event FundingTakenBack(uint256 indexed day, address indexed sponsor, uint256 amount);
    event DayPosted(uint256 indexed day, address[3] winners, bytes32 root, uint64 payableAt);
    event DayFlagged(uint256 indexed day, address indexed by, bytes32 evidenceHash, uint64 payableAt);
    event FlagCleared(uint256 indexed day, uint64 payableAt);
    event DayRejected(uint256 indexed day, bytes32 reasonHash, bool isVoid);
    event DayPaid(uint256 indexed day, uint256 refundable);
    event DayVoid(uint256 indexed day, uint256 refundable);
    event PrizePaid(uint256 indexed day, uint8 indexed rank, address indexed vault, uint256 amount);
    event PrizeDelayed(uint256 indexed day, uint8 indexed rank, address indexed vault, uint256 amount);
    event PrizeReturned(uint256 indexed day, uint8 indexed rank, address indexed vault, uint256 amount);
    event Refunded(uint256 indexed day, address indexed sponsor, uint256 amount);
    event RolesProposed(address scorer, address arbiter, uint64 effectiveAt);
    event RolesChanged(address scorer, address arbiter);

    error Unauthorized();
    error BadState();
    error BadParams();
    error WrongChain();

    constructor(address asset_, address factory_, address admin, address scorer_, address arbiter_, uint64 review_)
        Ownable(admin)
    {
        if (block.chainid != TESTNET && block.chainid != MAINNET) revert WrongChain();
        if (review_ < MIN_REVIEW || review_ > MAX_REVIEW || asset_ == address(0) || factory_ == address(0)) {
            revert BadParams();
        }
        REVIEW = review_;
        asset = IERC20(asset_);
        factory = IPyraVaultFactory(factory_);
        _checkRoles(scorer_, arbiter_, admin);
        roles = Roles(scorer_, arbiter_);
        emit RolesChanged(scorer_, arbiter_);
    }

    // ------------------------------------------------------------------ roles

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

    /// @dev Without an owner a lost scorer or arbiter key could never be replaced.
    function renounceOwnership() public pure override {
        revert BadState();
    }

    function _checkRoles(address s, address a, address admin) internal pure {
        if (s == address(0) || a == address(0) || s == a || s == admin || a == admin) revert BadParams();
    }

    // ---------------------------------------------------------------- reading

    function today() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function day(uint256 d) external view returns (Day memory) {
        return _days[d];
    }

    /// @notice The midnight at which the day is over.
    function endOf(uint256 d) public pure returns (uint256) {
        return (d + 1) * 1 days;
    }

    // ---------------------------------------------------------------- funding

    /// @notice The same amount for each of `count` days from `first`. A day takes money until its midnight.
    function fund(uint256 first, uint256 count, uint128 perDay) external nonReentrant {
        if (first < today() || first > today() + 366 || count == 0 || count > 31 || perDay == 0) revert BadParams();
        for (uint256 i; i < count; ++i) {
            Day storage x = _days[first + i];
            if (uint256(x.pool) + perDay > MAX_POOL) revert BadParams();
            x.pool += perDay;
            given[first + i][msg.sender] += perDay;
            emit DayFunded(first + i, msg.sender, perDay);
        }
        asset.safeTransferFrom(msg.sender, address(this), uint256(perDay) * count);
    }

    /// @notice A day that has not begun can be taken back. One that has begun is promised.
    function takeBack(uint256 d) external nonReentrant {
        uint128 amount = given[d][msg.sender];
        if (d <= today() || amount == 0) revert BadState();
        given[d][msg.sender] = 0;
        _days[d].pool -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit FundingTakenBack(d, msg.sender, amount);
    }

    // ----------------------------------------------------------------- result

    /// @notice Winners may include trailing zero addresses; one prize per ultimate owner.
    function post(uint256 d, address[3] calldata winners, bytes32 root) external {
        if (msg.sender != roles.scorer) revert Unauthorized();
        Day storage x = _days[d];
        uint256 end = endOf(d);
        if (
            x.status != Status.None || x.pool == 0 || block.timestamp < end || block.timestamp >= end + POST_WINDOW
                || root == bytes32(0)
        ) revert BadState();
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
        x.winners = winners;
        x.root = root;
        x.status = Status.Posted;
        x.reviewEnds = uint64(block.timestamp) + REVIEW;
        x.payableAt = x.reviewEnds;
        emit DayPosted(d, winners, root, x.payableAt);
    }

    /// @notice Any vault owner can hold a posted result once, until the arbiter answers or twelve hours pass.
    function flag(uint256 d, address vault, bytes32 evidenceHash) external {
        Day storage x = _days[d];
        if (!factory.isVault(vault) || IPyraVault(vault).owner() != msg.sender) revert Unauthorized();
        if (x.status != Status.Posted || x.flagged || block.timestamp >= x.payableAt) revert BadState();
        x.flagged = true;
        x.payableAt = uint64(block.timestamp) + FLAG_HOLD;
        emit DayFlagged(d, msg.sender, evidenceHash, x.payableAt);
    }

    /// @notice The arbiter looked and the result stands. The review everyone else was promised is still kept.
    function clearFlag(uint256 d) external {
        if (msg.sender != roles.arbiter) revert Unauthorized();
        Day storage x = _days[d];
        if (x.status != Status.Posted || !x.flagged || block.timestamp >= x.payableAt) revert BadState();
        x.payableAt = block.timestamp > x.reviewEnds ? uint64(block.timestamp) : x.reviewEnds;
        emit FlagCleared(d, x.payableAt);
    }

    /// @notice The result is wrong. Possible until it is paid. A second rejection makes the day void.
    function reject(uint256 d, bytes32 reasonHash) external {
        if (msg.sender != roles.arbiter) revert Unauthorized();
        Day storage x = _days[d];
        if (x.status != Status.Posted) revert BadState();
        bool isVoid = ++x.rejections >= MAX_REJECTIONS;
        x.status = Status.None;
        x.flagged = false;
        x.reviewEnds = 0;
        x.payableAt = 0;
        delete x.winners;
        x.root = bytes32(0);
        emit DayRejected(d, reasonHash, isVoid);
        if (isVoid) _void(d, x);
    }

    /// @notice No result came in time. Anyone can say so, and the sponsors are repaid.
    function voidDay(uint256 d) external {
        Day storage x = _days[d];
        if (x.status != Status.None || x.pool == 0 || block.timestamp < endOf(d) + POST_WINDOW) revert BadState();
        _void(d, x);
    }

    function _void(uint256 d, Day storage x) internal {
        x.status = Status.Void;
        x.refundable = x.pool;
        emit DayVoid(d, x.pool);
    }

    // ---------------------------------------------------------------- payment

    /// @notice Pays all three at once. One vault that cannot receive does not hold up the others.
    function pay(uint256 d) external nonReentrant {
        Day storage x = _days[d];
        if (x.status != Status.Posted || block.timestamp < x.payableAt) revert BadState();
        x.status = Status.Paid;
        for (uint8 r; r < 3; ++r) {
            if (x.winners[r] == address(0)) {
                x.settled |= uint8(1 << r);
                x.refundable += _share(x.pool, r);
            } else if (!_send(d, x, r)) {
                emit PrizeDelayed(d, r, x.winners[r], _share(x.pool, r));
            }
        }
        emit DayPaid(d, x.refundable);
    }

    /// @notice Tries a delayed prize again. After thirty days without success it goes back to the sponsors.
    function retry(uint256 d, uint8 rank) external nonReentrant {
        Day storage x = _days[d];
        if (rank > 2 || x.status != Status.Paid || x.settled & uint8(1 << rank) != 0) revert BadState();
        if (_send(d, x, rank)) return;
        if (block.timestamp < x.payableAt + RETRY_FOR) revert BadState();
        uint128 amount = _share(x.pool, rank);
        x.settled |= uint8(1 << rank);
        x.refundable += amount;
        emit PrizeReturned(d, rank, x.winners[rank], amount);
    }

    function _send(uint256 d, Day storage x, uint8 rank) internal returns (bool ok) {
        uint128 amount = _share(x.pool, rank);
        address vault = x.winners[rank];
        x.settled |= uint8(1 << rank);
        ok = asset.trySafeTransfer(vault, amount);
        if (ok) emit PrizePaid(d, rank, vault, amount);
        else x.settled &= ~uint8(1 << rank);
    }

    /// @notice Sends a sponsor their part of what nobody won. Anyone can call it; only the sponsor is paid.
    function refund(uint256 d, address sponsor) external nonReentrant {
        Day storage x = _days[d];
        if (x.refundable == 0) revert BadState();
        uint128 due = uint128(uint256(given[d][sponsor]) * x.refundable / x.pool) - refunded[d][sponsor];
        if (due == 0) revert BadState();
        refunded[d][sponsor] += due;
        asset.safeTransfer(sponsor, due);
        emit Refunded(d, sponsor, due);
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
