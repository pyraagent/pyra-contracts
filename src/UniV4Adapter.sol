// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapAdapter} from "./interfaces/IPyra.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24);
}

/// @title UniV4Adapter
/// @notice Exact-input swaps against one immutable, hookless Uniswap v4 pool.
///         Holds nothing between calls and always returns output to the caller.
contract UniV4Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT = 4295128739 + 1;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    IPoolManager public immutable manager;
    IStateView public immutable stateView;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    bytes32 public immutable poolId;

    error NotManager();
    error WrongPair();
    error BadInput();
    error PriceImpact();
    error TooLittleOut();

    constructor(address manager_, address stateView_, address c0, address c1, uint24 fee_, int24 spacing) {
        manager = IPoolManager(manager_);
        stateView = IStateView(stateView_);
        currency0 = c0;
        currency1 = c1;
        fee = fee_;
        tickSpacing = spacing;
        poolId = keccak256(abi.encode(PoolKey(c0, c1, fee_, spacing, address(0))));
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint16 maxImpactBps)
        external
        payable
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn == currency0 && tokenOut == currency1;
        if (!zeroForOne && !(tokenIn == currency1 && tokenOut == currency0)) revert WrongPair();
        if (
            amountIn == 0 || amountIn > uint128(type(int128).max) || maxImpactBps > 10_000
                || msg.value != (tokenIn == address(0) ? amountIn : 0)
        ) revert BadInput();
        bytes memory out =
            manager.unlock(abi.encode(msg.sender, tokenIn, tokenOut, zeroForOne, amountIn, minOut, maxImpactBps));
        amountOut = abi.decode(out, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (
            address payer,
            address tokenIn,
            address tokenOut,
            bool zeroForOne,
            uint256 amountIn,
            uint256 minOut,
            uint16 maxImpactBps
        ) = abi.decode(data, (address, address, address, bool, uint256, uint256, uint16));

        int256 delta = manager.swap(
            PoolKey(currency0, currency1, fee, tickSpacing, address(0)),
            SwapParams(zeroForOne, -int256(amountIn), _limit(zeroForOne, maxImpactBps)),
            ""
        );
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        (int128 inDelta, int128 outDelta) = zeroForOne ? (a0, a1) : (a1, a0);

        // A partial fill means the price limit was reached before the input was used up.
        if (inDelta >= 0 || uint256(uint128(-inDelta)) != amountIn) revert PriceImpact();
        if (outDelta <= 0 || uint256(uint128(outDelta)) < minOut) revert TooLittleOut();

        if (tokenIn == address(0)) {
            manager.settle{value: amountIn}();
        } else {
            manager.sync(tokenIn);
            IERC20(tokenIn).safeTransferFrom(payer, address(manager), amountIn);
            manager.settle();
        }
        uint256 amountOut = uint256(uint128(outDelta));
        manager.take(tokenOut, payer, amountOut);
        return abi.encode(amountOut);
    }

    /// @dev sqrt(1 +/- x) is approximated by 1 +/- x/2, which is tight for x <= 5%.
    function _limit(bool zeroForOne, uint16 bps) internal view returns (uint160) {
        (uint160 p,,,) = stateView.getSlot0(poolId);
        uint256 l = zeroForOne ? uint256(p) * (20_000 - bps) / 20_000 : uint256(p) * (20_000 + bps) / 20_000;
        if (l < MIN_SQRT) l = MIN_SQRT;
        if (l > MAX_SQRT) l = MAX_SQRT;
        return uint160(l);
    }
}
