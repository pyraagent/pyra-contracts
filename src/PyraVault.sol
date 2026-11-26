// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapter, IPyraEscrow, IPyraVaultFactory} from "./interfaces/IPyra.sol";

/// @title PyraVault
/// @notice Holds one agent's capital. The owner keeps custody: only the owner can withdraw.
///         An operator key may spend inside an expiring, revocable permission that this contract
///         enforces: per-transaction, per-day and lifetime limits plus destination allowlists.
contract PyraVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_FUNDED = 5e6; // $5, six-decimal stable asset
    uint256 public constant MAX_FUNDED = 1_000e6; // $1,000
    uint16 public constant IMPACT_CEILING_BPS = 500;
    uint64 public constant MAX_PERMISSION_LIFETIME = 90 days;

    struct Permission {
        address operator;
        uint64 expiresAt;
        uint16 maxImpactBps;
        uint128 perTxLimit;
        uint128 dailyLimit;
        uint128 totalLimit;
    }

    struct Config {
        Permission permission;
        address[] payees;
        address[] adapters;
        address[] escrows;
        address[] tokens; // address(0) is native ETH
    }

    address public factory;
    address public owner;
    IERC20 public asset;
    bytes32 public agentId;
    bool public retired;

    Permission public permission;
    uint128 public spentTotal;
    uint128 public spentToday;
    uint64 public spendDay;
    uint256 public fundedPrincipal;

    mapping(address => bool) public payeeAllowed;
    mapping(address => bool) public adapterAllowed;
    mapping(address => bool) public escrowAllowed;
    mapping(address => bool) public tokenAllowed;
    mapping(bytes32 => bool) public refUsed;

    event Deposited(address indexed from, uint256 amount, uint256 principal);
    event Withdrawn(address indexed token, address indexed to, uint256 amount, uint256 principal);
    event PermissionGranted(
        address indexed operator, uint64 expiresAt, uint128 perTx, uint128 daily, uint128 total, uint16 maxImpactBps
    );
    event PermissionRevoked(address indexed operator);
    event AllowlistChanged(bytes32 indexed kind, address indexed target, bool allowed);
    event Paid(address indexed payee, uint256 amount, bytes32 indexed ref);
    event Swapped(
        address indexed adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 indexed ref
    );
    event JobFunded(address indexed escrow, bytes32 indexed jobId, uint256 amount, bytes32 indexed ref);
    event Retired();

    error NotOwner();
    error NotOperator();
    error PermissionExpired();
    error OverPerTxLimit();
    error OverDailyLimit();
    error OverTotalLimit();
    error NotAllowlisted();
    error RefUsed();
    error BadAmount();
    error BadPermission();
    error FundingCap();
    error FundingFloor();
    error AlreadyInitialized();
    error VaultRetired();
    error NativeTransferFailed();
    error InsufficientOutput();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        _checkOperator();
        _;
    }

    /// @dev Locks the implementation; clones are initialised by the factory in the creating call.
    constructor() {
        factory = address(1);
    }

    receive() external payable {}

    function initialize(address owner_, address asset_, bytes32 agentId_, Config calldata cfg) external {
        if (factory != address(0)) revert AlreadyInitialized();
        factory = msg.sender;
        owner = owner_;
        asset = IERC20(asset_);
        agentId = agentId_;
        _set("payee", payeeAllowed, cfg.payees, true);
        _set("adapter", adapterAllowed, cfg.adapters, true);
        _set("escrow", escrowAllowed, cfg.escrows, true);
        _set("token", tokenAllowed, cfg.tokens, true);
        if (cfg.permission.operator != address(0)) _grant(cfg.permission);
    }

    // ------------------------------------------------------------------ owner

    function deposit(uint256 amount) external nonReentrant onlyOwner {
        _deposit(amount);
    }

    /// @dev A front-run permit leaves the allowance in place, so a failed permit call is ignored.
    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        onlyOwner
    {
        try IERC20Permit(address(asset)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _deposit(amount);
    }

    function _deposit(uint256 amount) internal {
        if (retired) revert VaultRetired();
        if (amount == 0) revert BadAmount();
        uint256 next = fundedPrincipal + amount;
        if (next > MAX_FUNDED) revert FundingCap();
        if (next < MIN_FUNDED) revert FundingFloor();
        fundedPrincipal = next;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, next);
    }

    /// @notice Owner-only exit. Always available, including while a permission is live.
    function withdraw(address token, uint256 amount, address to) external nonReentrant onlyOwner {
        if (to == address(0) || amount == 0) revert BadAmount();
        if (token == address(asset)) {
            fundedPrincipal = amount >= fundedPrincipal ? 0 : fundedPrincipal - amount;
        }
        _send(token, to, amount);
        emit Withdrawn(token, to, amount, fundedPrincipal);
    }

    function grantPermission(Permission calldata p) external onlyOwner {
        if (retired) revert VaultRetired();
        _grant(p);
    }

    function revokePermission() public onlyOwner {
        address op = permission.operator;
        delete permission;
        emit PermissionRevoked(op);
    }

    function setPayees(address[] calldata a, bool ok) external onlyOwner {
        _set("payee", payeeAllowed, a, ok);
    }

    function setAdapters(address[] calldata a, bool ok) external onlyOwner {
        _set("adapter", adapterAllowed, a, ok);
    }

    function setEscrows(address[] calldata a, bool ok) external onlyOwner {
        _set("escrow", escrowAllowed, a, ok);
    }

    function setTokens(address[] calldata a, bool ok) external onlyOwner {
        _set("token", tokenAllowed, a, ok);
    }

    /// @notice Ends the agent on-chain and frees an owner slot. Withdrawals keep working.
    function retire() external onlyOwner {
        if (retired) revert VaultRetired();
        retired = true;
        revokePermission();
        IPyraVaultFactory(factory).onRetired(owner);
        emit Retired();
    }

    // --------------------------------------------------------------- operator

    /// @notice Pays an allowlisted payee once per `ref`. A ref can never settle twice.
    function pay(address payee, uint128 amount, bytes32 ref) external nonReentrant onlyOperator {
        if (!payeeAllowed[payee]) revert NotAllowlisted();
        _useRef(ref);
        _consume(amount);
        asset.safeTransfer(payee, amount);
        emit Paid(payee, amount, ref);
    }

    /// @notice Swaps through an allowlisted adapter. Buying with the asset consumes spend limits.
    function swap(address adapter, address tokenIn, address tokenOut, uint128 amountIn, uint256 minOut, bytes32 ref)
        external
        nonReentrant
        onlyOperator
        returns (uint256 amountOut)
    {
        if (!adapterAllowed[adapter]) revert NotAllowlisted();
        if (tokenIn == tokenOut || amountIn == 0 || minOut == 0) revert BadAmount();
        if (tokenIn != address(asset) && !tokenAllowed[tokenIn]) revert NotAllowlisted();
        if (tokenOut != address(asset) && !tokenAllowed[tokenOut]) revert NotAllowlisted();
        _useRef(ref);
        if (tokenIn == address(asset)) _consume(amountIn);

        uint256 before = _balance(tokenOut);
        uint256 value;
        if (tokenIn == address(0)) value = amountIn;
        else IERC20(tokenIn).forceApprove(adapter, amountIn);
        ISwapAdapter(adapter).swapExactIn{value: value}(tokenIn, tokenOut, amountIn, minOut, permission.maxImpactBps);
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(adapter, 0);

        amountOut = _balance(tokenOut) - before;
        if (amountOut < minOut) revert InsufficientOutput();
        emit Swapped(adapter, tokenIn, tokenOut, amountIn, amountOut, ref);
    }

    /// @notice Hires another agent by funding an escrow job from this vault.
    function fundJob(
        address escrow,
        bytes32 key,
        uint128 amount,
        uint64 deadline,
        uint32 reviewPeriod,
        bytes32 specHash,
        bytes32 ref
    ) external nonReentrant onlyOperator returns (bytes32 jobId) {
        if (!escrowAllowed[escrow]) revert NotAllowlisted();
        _useRef(ref);
        _consume(amount);
        asset.forceApprove(escrow, amount);
        jobId = IPyraEscrow(escrow).createJob(key, amount, deadline, reviewPeriod, specHash);
        asset.forceApprove(escrow, 0);
        emit JobFunded(escrow, jobId, amount, ref);
    }

    /// @notice Client actions on jobs this vault funded. 0 release, 1 dispute, 2 cancel.
    /// @dev The owner can always act; the operator needs a live permission.
    function settleJob(address escrow, bytes32 jobId, uint8 action) external nonReentrant {
        if (msg.sender != owner) _checkOperator();
        if (!escrowAllowed[escrow]) revert NotAllowlisted();
        if (action == 0) IPyraEscrow(escrow).release(jobId);
        else if (action == 1) IPyraEscrow(escrow).dispute(jobId);
        else if (action == 2) IPyraEscrow(escrow).cancel(jobId);
        else revert BadAmount();
    }

    // ------------------------------------------------------------------ views

    function remainingToday() external view returns (uint256) {
        Permission memory p = permission;
        if (p.operator == address(0) || block.timestamp >= p.expiresAt) return 0;
        uint256 usedToday = spendDay == uint64(block.timestamp / 1 days) ? spentToday : 0;
        uint256 daily = p.dailyLimit > usedToday ? p.dailyLimit - usedToday : 0;
        uint256 total = p.totalLimit > spentTotal ? p.totalLimit - spentTotal : 0;
        return daily < total ? daily : total;
    }

    // --------------------------------------------------------------- internal

    function _checkOperator() internal view {
        Permission memory p = permission;
        if (p.operator == address(0) || msg.sender != p.operator) revert NotOperator();
        if (block.timestamp >= p.expiresAt) revert PermissionExpired();
    }

    function _grant(Permission memory p) internal {
        if (
            p.operator == address(0) || p.operator == address(this) || p.expiresAt <= block.timestamp
                || p.expiresAt > block.timestamp + MAX_PERMISSION_LIFETIME || p.perTxLimit == 0
                || p.perTxLimit > p.dailyLimit || p.dailyLimit > p.totalLimit || p.totalLimit > MAX_FUNDED
                || p.maxImpactBps == 0 || p.maxImpactBps > IMPACT_CEILING_BPS
        ) revert BadPermission();
        permission = p;
        spentTotal = 0; // a new grant is a new lifetime budget; today's spend still counts
        emit PermissionGranted(p.operator, p.expiresAt, p.perTxLimit, p.dailyLimit, p.totalLimit, p.maxImpactBps);
    }

    function _consume(uint128 amount) internal {
        Permission memory p = permission;
        if (amount == 0) revert BadAmount();
        if (amount > p.perTxLimit) revert OverPerTxLimit();
        uint64 today = uint64(block.timestamp / 1 days);
        if (spendDay != today) {
            spendDay = today;
            spentToday = 0;
        }
        if (uint256(spentToday) + amount > p.dailyLimit) revert OverDailyLimit();
        if (uint256(spentTotal) + amount > p.totalLimit) revert OverTotalLimit();
        spentToday += amount;
        spentTotal += amount;
    }

    function _useRef(bytes32 ref) internal {
        if (ref == bytes32(0) || refUsed[ref]) revert RefUsed();
        refUsed[ref] = true;
    }

    function _set(bytes32 kind, mapping(address => bool) storage m, address[] calldata a, bool ok) internal {
        for (uint256 i; i < a.length; ++i) {
            m[a[i]] = ok;
            emit AllowlistChanged(kind, a[i], ok);
        }
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
