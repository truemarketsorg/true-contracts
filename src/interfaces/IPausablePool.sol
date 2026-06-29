// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IPausablePool
/// @notice Interface for hooks that support pausing pools to prevent swaps
/// @dev Implement this interface to enable pool pause functionality during distribution
interface IPausablePool {
    /// @notice Check if a pool is paused
    /// @param poolId The pool to check
    /// @return True if the pool is paused
    function poolPaused(PoolId poolId) external view returns (bool);

    /// @notice Pause a pool to prevent swaps
    /// @param poolId The pool to pause
    function pausePool(PoolId poolId) external;

    /// @notice Unpause a pool to allow swaps
    /// @param poolId The pool to unpause
    function unpausePool(PoolId poolId) external;
}
