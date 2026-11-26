// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPyraVaultFactory {
    function isVault(address vault) external view returns (bool);
    function onRetired(address owner) external;
}

interface IPyraVault {
    function owner() external view returns (address);
}

interface ISwapAdapter {
    /// @notice Sells `amountIn` of tokenIn for tokenOut. The caller receives the output.
    /// @dev Reverts unless the whole input fills inside `maxImpactBps` of the pool price at entry.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint16 maxImpactBps)
        external
        payable
        returns (uint256 amountOut);
}

interface IPyraEscrow {
    function createJob(bytes32 key, uint128 amount, uint64 deadline, uint32 reviewPeriod, bytes32 specHash)
        external
        returns (bytes32 jobId);
    function release(bytes32 jobId) external;
    function dispute(bytes32 jobId) external;
    function cancel(bytes32 jobId) external;
}
