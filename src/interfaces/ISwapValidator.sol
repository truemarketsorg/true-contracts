pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
}