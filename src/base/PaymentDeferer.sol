pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IOrderManager} from "../interfaces/IOrderManager.sol";
import {OrderManagerState} from "./OrderManagerState.sol";

/// @title PaymentDeferer
/// @notice Abstract contract for deferring payments in the order management system
/// @dev Allows minting claims for future payments and resolving them later
abstract contract PaymentDeferer is OrderManagerState {
    using CurrencyLibrary for Currency;

    /// @notice Struct containing information about a deferred payment
    /// @param currency The currency to be paid
    /// @param amount The amount to be paid
    /// @param to The recipient address
    /// @param nonce A unique nonce to prevent hash collisions
    /// @param reason The reason why the payment was deferred
    struct DeferredPayment {
        Currency currency;
        uint256 amount;
        address to;
        uint256 nonce;
        IOrderManager.PaymentDeferredReason reason;
    }

    /// @notice Mapping from payment hash ID to deferred payment details
    /// @dev Hash ID is keccak256 of the payment struct
    mapping(bytes32 => DeferredPayment) public deferredPayments;

    /// @notice Mapping from currency ID to deferred amount
    /// @dev Used to exclude the deferred amounts from the withdrawable balance
    mapping(uint256 => uint256) internal _deferredAmounts;

    /// @notice Counter for generating unique nonces for deferred payments
    uint256 private _paymentNonce;

    /// @notice Admin safe address to receive funds when original recipient cannot receive them
    /// @dev Used for handling blacklisted addresses or other transfer failures
    address public adminSafe;

    /// @notice Resolves a deferred payment by burning minted claims and taking tokens
    /// @dev Burns the minted tokens from this contract and takes them to the recipient
    ///      If the payment was deferred due to UnableToTransfer (e.g., blacklist), sends to adminSafe instead
    /// @param hashId The hash identifier of the deferred payment to resolve
    function _resolveDeferredPayment(bytes32 hashId) internal {
        DeferredPayment memory payment = deferredPayments[hashId];

        // Update state before external calls (checks-effects-interactions pattern)
        delete deferredPayments[hashId];
        _deferredAmounts[payment.currency.toId()] -= payment.amount;

        // Make external calls after state updates
        poolManager.burn(address(this), payment.currency.toId(), payment.amount);

        // If payment was deferred due to transfer failure (e.g., blacklist), send to adminSafe
        // Otherwise send to the original recipient
        address recipient =
            payment.reason == IOrderManager.PaymentDeferredReason.UnableToTransfer ? adminSafe : payment.to;

        poolManager.take(payment.currency, recipient, payment.amount);

        emit IOrderManager.DeferredPaymentResolved(Currency.unwrap(payment.currency), payment.to, payment.amount);
    }

    /// @notice Creates a deferred payment by minting claims for future resolution
    /// @dev Mints tokens to this contract representing a future payment obligation
    /// @param currency The currency to defer payment for
    /// @param amount The amount to defer
    /// @param to The recipient address for the future payment
    /// @param reason Description of why the payment was deferred
    function _deferPayment(Currency currency, uint256 amount, address to, IOrderManager.PaymentDeferredReason reason)
        internal
    {
        poolManager.mint(address(this), currency.toId(), amount);

        // Increment nonce to ensure unique hash for each payment
        // Safe to overflow as old payments should be resolved before reaching max uint256
        uint256 currentNonce;
        unchecked {
            currentNonce = ++_paymentNonce;
        }

        DeferredPayment memory payment = DeferredPayment(currency, amount, to, currentNonce, reason);

        bytes32 hashId = keccak256(abi.encode(payment));

        deferredPayments[hashId] = payment;

        _deferredAmounts[currency.toId()] += amount;

        emit IOrderManager.PaymentDeferred(hashId, reason);
    }

    /// @notice Sets the admin safe address for receiving funds from blacklisted addresses
    /// @param adminSafe_ The new admin safe address
    function _setAdminSafe(address adminSafe_) internal {
        adminSafe = adminSafe_;
    }
}
