// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IOrderManager} from "./IOrderManager.sol";
import {ISwapValidator} from "./ISwapValidator.sol";

interface ITruthMarketHook {
    /// @notice The fee numerator used to calculate the fee amount
    /// @return The fee numerator (e.g., 36 for 0.36% fee)
    function feeNumerator() external view returns (uint256);

    /// @notice The order manager contract
    /// @return The order manager instance
    function orderManager() external view returns (IOrderManager);

    /// @notice The fee collector address
    /// @return The address that collects fees
    function feeCollector() external view returns (address);

    /// @notice The swap validator contract
    /// @return The swap validator instance
    function swapValidator() external view returns (ISwapValidator);

    /// @notice The pool manager contract
    /// @return The pool manager instance
    function poolManager() external view returns (IPoolManager);

    /// @notice Whitelist consulted in beforeInitialize to authorize the caller
    ///         of poolManager.initialize for hook-managed pools
    /// @param initializer Address being checked
    /// @return True if the address is allowed to initialize pools through this hook
    function authorizedPoolInitializers(address initializer) external view returns (bool);
}
