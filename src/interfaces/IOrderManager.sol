pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Order} from "../libraries/Order.sol";

interface IOrderManager {
    error Unauthorized();

    error NotPoolManager();

    error PoolNotWhitelisted(PoolId poolId);

    error PoolNotSupported(PoolId poolId);

    error OrderIdCollision(uint32 orderId);

    error InvalidRecipient(address recipient);

    event OrderCreated(
        PoolId indexed poolId,
        uint32 indexed orderId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bool zeroForOne,
        bool enablePartialFill,
        uint256 liquidity
    );

    event OrderFilled(PoolId indexed poolId, uint32 indexed orderId, uint128 tradedAmount);

    event OrderCancelled(PoolId indexed poolId, uint32 indexed orderId, uint128 remainingAmount, uint128 tradedAmount);

    event OrderPartiallyFilled(
        PoolId indexed poolId,
        uint32 indexed orderId,
        uint128 remainingAmount,
        uint128 tradedAmount,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    );

    event MinimumOrderAmountUpdated(address indexed token, uint256 minimumOrderAmount);

    event MaximumExecutionCountUpdated(uint256 maximumExecutionCount);

    event ExecutionDeferred(PoolId indexed poolId, bytes32 indexed hashId);

    event DeferredExecutionResolved(PoolId indexed poolId, bytes32 indexed hashId, int24 fromTick, int24 toTick);

    enum PaymentDeferredReason {
        InsufficientFundsTemporarily,
        UnableToTransfer
    }

    event PaymentDeferred(bytes32 indexed hashId, PaymentDeferredReason reason);

    event DeferredPaymentResolved(address indexed token, address indexed to, uint256 amount);

    event FeeRecipientUpdated(address indexed feeRecipient);

    event PoolWhitelistUpdated(PoolId indexed poolId, bool whitelisted);

    event OrderIdCollisionDetected(PoolId indexed poolId, uint32 indexed orderId);

    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    event AdminSafeUpdated(address indexed adminSafe);

    struct CreateOrderParams {
        PoolKey poolKey;
        uint128 amountIn;
        int24 tickLower;
        int24 tickUpper;
        bool zeroForOne;
        bool enablePartialFill;
    }

    struct CancelOrderParams {
        PoolKey poolKey;
        uint32 orderId;
        uint128 amount0Min;
        uint128 amount1Min;
    }

    /// @notice Sets the minimum order amount required for a specific token
    /// @param token The token address to set the minimum for
    /// @param minimumOrderAmount_ The new minimum order amount for this token
    function setMinimumOrderAmount(address token, uint256 minimumOrderAmount_) external;

    /// @notice Sets the maximum number of orders that can be executed in a single transaction
    /// @param maximumExecutionCount_ The new maximum execution count
    function setMaximumExecutionCount(uint256 maximumExecutionCount_) external;

    /// @notice Sets the fee recipient address
    /// @param feeRecipient_ The new fee recipient address
    function setFeeRecipient(address feeRecipient_) external;

    /// @notice Updates the whitelist status of a pool
    /// @param poolId The ID of the pool to update
    /// @param whitelisted Whether the pool should be whitelisted
    function setPoolWhitelist(PoolId poolId, bool whitelisted) external;

    /// @notice Resolves deferred executions
    /// @param poolKey The key of the pool containing the executions
    /// @param hashId The hash of the executions to resolve
    function resolveDeferredExecution(PoolKey calldata poolKey, bytes32 hashId) external;

    /// @notice Resolves deferred payments
    /// @param hashId The hash of the payment to resolve
    function resolveDeferredPayment(bytes32 hashId) external;

    /// @notice Creates a new order in the specified pool
    /// @param params The parameters for creating the order
    /// @return orderId The ID of the created order
    function createOrder(CreateOrderParams calldata params) external returns (uint32 orderId);

    /// @notice Cancels an existing order
    /// @param params The parameters for canceling the order including poolKey, orderId, and minimum amounts
    function cancelOrder(CancelOrderParams calldata params) external;

    /// @notice Moves the tick of a pool from one position to another
    /// @param key The key of the pool
    /// @param fromTick The current tick position
    /// @param toTick The target tick position
    /// @param sqrtPriceX96 Square root of the price of the pool, in Q96 precision
    function movePoolTick(PoolKey calldata key, int24 fromTick, int24 toTick, uint160 sqrtPriceX96) external;

    /// @notice Retrieves the details of a pending order
    /// @param poolId The ID of the pool containing the order
    /// @param orderId The ID of the order to query
    /// @return The pending order details
    function pendingOrder(PoolId poolId, uint32 orderId) external view returns (Order memory);

    /// @notice Rescues tokens from the contract
    /// @param token The token to rescue
    /// @param to The address to send the tokens to
    /// @param amount The amount of tokens to rescue
    function rescueToken(address token, address to, uint256 amount) external;

    /// @notice Sets the admin safe address for receiving funds from blacklisted addresses
    /// @param adminSafe_ The new admin safe address
    function setAdminSafe(address adminSafe_) external;
}
