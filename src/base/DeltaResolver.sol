pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {OrderManagerState} from "./OrderManagerState.sol";

/// @title DeltaResolver
/// @notice Abstract contract for resolving balance deltas in the Uniswap V4 pool manager
/// @dev Handles taking tokens from the pool manager or settling tokens into it based on deltas
abstract contract DeltaResolver is OrderManagerState {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Enum representing the result of a delta resolution operation
    /// @dev Taken: Tokens were taken from the pool manager
    /// @dev Settled: Tokens were settled into the pool manager
    /// @dev InsufficientDeposits: Not enough deposits in the pool manager to take
    /// @dev TakeFailed: Token transfer failed (e.g., recipient is blacklisted)
    /// @dev ZeroDelta: No delta to resolve
    enum ResolveResult {
        Taken,
        Settled,
        InsufficientDeposits,
        TakeFailed,
        ZeroDelta
    }

    /// @notice Address that receives fees
    address public feeRecipient;

    /// @notice Initializes the contract with a fee recipient
    /// @param feeRecipient_ The address that will receive fees
    constructor(address feeRecipient_) {
        feeRecipient = feeRecipient_;
    }

    /// @notice Sets a new fee recipient address
    /// @dev Internal function to update the fee recipient
    /// @param feeRecipient_ The new fee recipient address
    function _setFeeRecipient(address feeRecipient_) internal {
        feeRecipient = feeRecipient_;
    }

    /// @notice Abstract function to handle payment of a specific currency
    /// @dev Must be implemented by inheriting contracts to define payment logic
    /// @param currency The currency to pay
    /// @param payer The address that will pay
    /// @param amount The amount to pay
    function _pay(Currency currency, address payer, uint256 amount) internal virtual;

    /// @notice Takes tokens from or settles tokens into the pool manager based on the delta amount
    /// @dev Positive amounts result in taking, negative amounts result in settling
    /// @param currency The currency to take or settle
    /// @param amount The delta amount (positive for take, negative for settle)
    /// @param taker The address that receives tokens when taking
    /// @param payer The address that pays tokens when settling
    /// @return The result of the operation
    function _takeOrSettle(Currency currency, int128 amount, address taker, address payer)
        internal
        returns (ResolveResult)
    {
        if (amount > 0) {
            uint256 amount256 = uint256(uint128(amount));

            uint256 deposits = currency.balanceOf(address(poolManager));

            if (deposits < amount256) {
                return ResolveResult.InsufficientDeposits;
            }

            // Use try-catch to handle blacklisted addresses gracefully
            try poolManager.take(currency, taker, amount256) {
                return ResolveResult.Taken;
            } catch {
                // Transfer failed (likely due to blacklist)
                return ResolveResult.TakeFailed;
            }
        }

        if (amount < 0) {
            poolManager.sync(currency);
            _pay(currency, payer, uint256(uint128(-amount)));
            poolManager.settle();

            return ResolveResult.Settled;
        }

        return ResolveResult.ZeroDelta;
    }

    /// @notice Resolves the entire currency delta for this contract
    /// @dev Takes or settles the full outstanding delta amount
    /// @param currency The currency to resolve
    /// @param taker The address that receives tokens when taking
    /// @param payer The address that pays tokens when settling
    /// @return result The result of the operation
    /// @return amount The delta amount that was resolved
    function _takeOrSettleAll(Currency currency, address taker, address payer)
        internal
        returns (ResolveResult result, int256 amount)
    {
        amount = poolManager.currencyDelta(address(this), currency);

        if (amount > 0) {
            uint256 amount256 = uint256(amount);

            uint256 deposits = currency.balanceOf(address(poolManager));

            if (deposits < amount256) {
                return (ResolveResult.InsufficientDeposits, amount);
            }

            // Use try-catch to handle blacklisted addresses gracefully
            try poolManager.take(currency, taker, amount256) {
                return (ResolveResult.Taken, amount);
            } catch {
                // Transfer failed (likely due to blacklist)
                return (ResolveResult.TakeFailed, amount);
            }
        }

        if (amount < 0) {
            poolManager.sync(currency);
            _pay(currency, payer, uint256(-amount));
            poolManager.settle();

            return (ResolveResult.Settled, amount);
        }

        return (ResolveResult.ZeroDelta, 0);
    }

    /// @notice Clears any positive deltas for both currencies in a pool
    /// @dev Uses the pool manager's clear function to zero out positive deltas
    /// @param key The pool key containing both currencies to clear
    function _clearDelta(PoolKey memory key) internal {
        int256 delta0 = poolManager.currencyDelta(address(this), key.currency0);

        if (delta0 > 0) {
            poolManager.clear(key.currency0, uint256(delta0));
        }

        int256 delta1 = poolManager.currencyDelta(address(this), key.currency1);

        if (delta1 > 0) {
            poolManager.clear(key.currency1, uint256(delta1));
        }
    }
}
