pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface ISwapValidator {
    /// @notice Validates a swap after execution
    /// @dev Reverts if validation fails
    /// @param sender The address initiating the swap
    /// @param poolKey The pool being swapped in
    /// @param params The swap parameters
    /// @param delta The balance changes from the swap
    /// @param hookData Additional data from the hook
    function validateAfterSwap(
        address sender,
        PoolKey calldata poolKey,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external;

    /// @notice Sets tick boundaries for a pool
    /// @param poolId The pool ID
    /// @param tickLowerBoundary The lower tick boundary
    /// @param tickUpperBoundary The upper tick boundary
    function setBoundaries(PoolId poolId, int24 tickLowerBoundary, int24 tickUpperBoundary) external;
}