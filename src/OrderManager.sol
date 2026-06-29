pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IPermit2.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {ExecutionDeferer} from "./base/ExecutionDeferer.sol";
import {OrderManagerState} from "./base/OrderManagerState.sol";
import {PaymentDeferer} from "./base/PaymentDeferer.sol";
import "./interfaces/IOrderManager.sol";
import {Order, OrderLibrary} from "./libraries/Order.sol";
import {OrderBook, OrderBookLibrary} from "./libraries/OrderBook.sol";
import {OrderValidation} from "./libraries/OrderValidation.sol";
import {PackedOrderId, PackedOrderIdLibrary} from "./libraries/PackedOrderId.sol";
import {Roles} from "./libraries/Roles.sol";
import {TransientUint32Set} from "./libraries/TransientUint32Set.sol";

contract OrderManager is
    IOrderManager,
    IUnlockCallback,
    AccessControl,
    OrderManagerState,
    DeltaResolver,
    ExecutionDeferer,
    PaymentDeferer
{
    using OrderBookLibrary for OrderBook;
    using PackedOrderIdLibrary for PackedOrderId;
    using PackedOrderIdLibrary for PackedOrderId[];
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;
    using SlippageCheck for BalanceDelta;
    using TransientUint32Set for TransientUint32Set.Set;
    using OrderLibrary for Order;

    enum ActionType {
        ModifyLiquidity,
        ResolveDeferredTickRange,
        ResolveDeferredPayment,
        WithdrawToken
    }

    enum PartialFillResult {
        NotFilled,
        NewOrderCreated,
        DustSettled
    }

    struct ModifyLiquidityPayload {
        PoolKey key;
        ModifyLiquidityParams params;
        bytes hookData;
        address payer;
        address taker;
    }

    struct ResolveDeferredPaymentPayload {
        bytes32 hashId;
    }

    struct WithdrawTokenPayload {
        Currency currency;
        uint256 amount;
    }

    struct ResolveDeferredTickRangePayload {
        PoolKey key;
        bytes32 hashId;
    }

    /// @notice Hard cap on orders queued at a single tick threshold.
    /// @dev Prevents a single dense tick from exceeding the block gas limit when
    ///      the resolver retries a deferred tick range with unbounded `maxOrders`
    ///      (see `_processTickRange`). Measured at ~29k gas per order end-to-end
    ///      through `moveTick` + `_executeOrders`; 256 orders ≈ 7.4M gas, leaving
    ///      ample block-gas headroom on Base. The cap is enforced only at user
    ///      entry (`createOrder`) — partial-fill sub-order creation and requeue
    ///      paths intentionally bypass it so swap callbacks cannot revert from a
    ///      tick reaching the cap mid-execution.
    uint256 public constant MAX_ORDERS_PER_TICK = 256;

    IAllowanceTransfer internal immutable _permit2;

    uint256 private _orderExecutionNonce = 0;

    mapping(address => uint256) private _minimumOrderAmount;

    mapping(PoolId => mapping(uint32 => Order)) public pendingOrders;

    mapping(PoolId => OrderBook) internal _orderBooks;

    mapping(PoolId => bool) public poolWhitelist;

    constructor(address poolManager_, address permit2_, address feeRecipient_)
        OrderManagerState(poolManager_)
        DeltaResolver(feeRecipient_)
    {
        _permit2 = IAllowanceTransfer(permit2_);
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
        // Initialize adminSafe to feeRecipient to ensure funds can be recovered
        _setAdminSafe(feeRecipient_);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (ActionType actionType, bytes memory encodedPayload) = abi.decode(data, (ActionType, bytes));

        if (actionType == ActionType.ModifyLiquidity) {
            ModifyLiquidityPayload memory payload = abi.decode(encodedPayload, (ModifyLiquidityPayload));

            (BalanceDelta callerDelta, BalanceDelta feesDelta) =
                poolManager.modifyLiquidity(payload.key, payload.params, payload.hookData);

            BalanceDelta principalDelta = callerDelta - feesDelta;

            _safeTakeOrSettle(payload.key.currency0, principalDelta.amount0(), payload.taker, payload.payer);
            _safeTakeOrSettle(payload.key.currency1, principalDelta.amount1(), payload.taker, payload.payer);

            // fee delta is always expected to be positive
            _safeTakeOrSettle(payload.key.currency0, feesDelta.amount0(), feeRecipient, address(0));
            _safeTakeOrSettle(payload.key.currency1, feesDelta.amount1(), feeRecipient, address(0));

            // clear dust delta
            _clearDelta(payload.key);

            return abi.encode(principalDelta);
        } else if (actionType == ActionType.ResolveDeferredTickRange) {
            ResolveDeferredTickRangePayload memory payload =
                abi.decode(encodedPayload, (ResolveDeferredTickRangePayload));
            _handleDeferredTickRange(payload.key, payload.hashId);
        } else if (actionType == ActionType.ResolveDeferredPayment) {
            ResolveDeferredPaymentPayload memory payload = abi.decode(encodedPayload, (ResolveDeferredPaymentPayload));
            _resolveDeferredPayment(payload.hashId);
        } else if (actionType == ActionType.WithdrawToken) {
            WithdrawTokenPayload memory payload = abi.decode(encodedPayload, (WithdrawTokenPayload));
            _withdrawToken(payload.currency, payload.amount);
        }

        return new bytes(0);
    }

    function setMinimumOrderAmount(address token, uint256 minimumOrderAmount_) external onlyRole(Roles.OPERATOR_ROLE) {
        _minimumOrderAmount[token] = minimumOrderAmount_;
        emit MinimumOrderAmountUpdated(token, minimumOrderAmount_);
    }

    function setMaximumExecutionCount(uint256 maximumExecutionCount_) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        maximumExecutionCount = maximumExecutionCount_;
        emit MaximumExecutionCountUpdated(maximumExecutionCount_);
    }

    function setMaxTicksPerSwapCallback(uint256 maxTicks_) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (maxTicks_ == 0) revert InvalidMaxTicks();
        maxTicksPerSwapCallback = maxTicks_;
        emit IOrderManager.MaxTicksPerSwapCallbackUpdated(maxTicks_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        _setFeeRecipient(feeRecipient_);
        emit FeeRecipientUpdated(feeRecipient_);
    }

    function setPoolWhitelist(PoolId poolId, bool whitelisted) external onlyRole(Roles.WHITELIST_MANAGER_ROLE) {
        poolWhitelist[poolId] = whitelisted;
        emit PoolWhitelistUpdated(poolId, whitelisted);
    }

    function setAdminSafe(address adminSafe_) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        _setAdminSafe(adminSafe_);
        emit AdminSafeUpdated(adminSafe_);
    }

    function resolveDeferredPayment(bytes32 hashId) external onlyRole(Roles.ORDER_RESOLVER_ROLE) {
        poolManager.unlock(
            abi.encode(ActionType.ResolveDeferredPayment, abi.encode(ResolveDeferredPaymentPayload(hashId)))
        );
    }

    function resolveDeferredTickRange(PoolKey calldata poolKey, bytes32 hashId)
        external
        onlyRole(Roles.ORDER_RESOLVER_ROLE)
    {
        poolManager.unlock(
            abi.encode(
                ActionType.ResolveDeferredTickRange, abi.encode(ResolveDeferredTickRangePayload(poolKey, hashId))
            )
        );
    }

    /// @notice Rescues tokens that are stuck in the contract
    /// @dev This function handles two scenarios:
    ///      1. ERC6909 tokens stuck in pool manager due to deferred payment hash collisions
    ///      2. ERC20 reward tokens accumulated from liquidity positions
    ///
    ///      The function first withdraws ALL available balance from the pool manager,
    ///      then transfers only the requested amount to the recipient.
    ///      Any remaining tokens are intentionally kept in the OrderManager contract
    ///      for future rescue operations. This design allows for:
    ///      - Batch withdrawal from pool manager (gas efficient)
    ///      - Granular control over distribution amounts
    ///      - Multiple rescue operations without repeated pool manager interactions
    ///
    /// @param token The address of the token to rescue
    /// @param to The recipient address for the rescued tokens
    /// @param amount The amount of tokens to transfer to the recipient
    function rescueToken(address token, address to, uint256 amount) external onlyRole(Roles.TOKEN_RESCUER_ROLE) {
        if (to == address(0)) {
            revert InvalidRecipient(to);
        }

        Currency currency = Currency.wrap(token);

        // First, withdraw all available tokens from the pool manager
        // exclude the deferred amounts to avoid withdrawing tokens that are already being deferred
        // This makes stuck ERC6909 tokens accessible as ERC20 in this contract
        uint256 withdrawable = poolManager.balanceOf(address(this), currency.toId()) - _deferredAmounts[currency.toId()];

        if (withdrawable > 0) {
            poolManager.unlock(
                abi.encode(ActionType.WithdrawToken, abi.encode(WithdrawTokenPayload(currency, withdrawable)))
            );
        }

        // Transfer only the requested amount to the recipient
        // Any excess tokens remain in this contract by design
        currency.transfer(to, amount);

        emit TokenRescued(token, to, amount);
    }

    /// @notice Processes limit orders when pool tick moves between two price levels
    /// @dev Called by V4 hooks during swaps to execute crossed limit orders
    ///
    /// HIGH-VOLUME POOL SCENARIO - PRICE WHIPSAW:
    /// In volatile markets with rapid price movements, the deferred execution mechanism
    /// handles order processing as follows:
    ///
    /// Example Timeline:
    /// T=0: Large trade moves tick 1000 → 1100
    ///      - Collects 500+ orders in range
    ///      - Executes first 100 orders immediately (maximumExecutionCount)
    ///      - Defers remaining 400+ orders for later processing
    /// T=1: Market activity reverses price to tick 1050
    /// T=5: Deferred execution resolves
    ///      - Current tick = 1050
    ///      - Adjusted range becomes (1000, 1050) via _validateAndAdjustTickRange
    ///      - Orders at ticks 1051-1099 get pushed back to orderbook
    ///
    /// This ensures orders are only executed within valid tick ranges at resolution time.
    ///
    /// @param poolKey The key identifying the pool
    /// @param fromTick Starting tick of the price movement
    /// @param toTick Ending tick of the price movement
    /// @param sqrtPriceX96 Square root of the price of the pool, in Q96 precision
    function movePoolTick(PoolKey calldata poolKey, int24 fromTick, int24 toTick, uint160 sqrtPriceX96)
        external
        onlyRole(Roles.V4_HOOK_ROLE)
    {
        PoolId poolId = poolKey.toId();

        if (!poolWhitelist[poolId]) {
            return;
        }

        _collectAndProcessOrders(
            poolKey,
            fromTick,
            toTick,
            fromTick,
            toTick,
            toTick,
            sqrtPriceX96,
            maxTicksPerSwapCallback,
            maximumExecutionCount
        );
    }

    /// @notice Single entry point for moveTick + execute. moveTick's maxOrders bound
    ///         guarantees extracted orders fit within budget — no split needed.
    ///         Also ensures the library function is inlined only once.
    function _collectAndProcessOrders(
        PoolKey memory key,
        int24 moveFrom,
        int24 moveTo,
        int24 origFrom,
        int24 origTo,
        int24 currentTick,
        uint160 sqrtPriceX96,
        uint256 maxTicks,
        uint256 maxOrders
    ) private {
        PoolId poolId = key.toId();
        OrderBook storage orderBook = _orderBooks[poolId];

        (PackedOrderId[] memory orderIds, int24 cursor, bool complete) =
            orderBook.moveTick(moveFrom, moveTo, maxTicks, maxOrders);

        if (!complete) {
            _deferTickRange(poolId, origFrom, cursor, origTo);
        }

        if (orderIds.length > 0) {
            _executeOrders(
                key,
                orderIds,
                origFrom,
                origTo,
                BatchBounds({moveFrom: moveFrom, moveTo: moveTo, cursor: cursor}),
                currentTick,
                sqrtPriceX96
            );
        }
    }

    /// @inheritdoc ExecutionDeferer
    function _processTickRange(
        PoolKey memory key,
        DeferredTickRange memory deferred,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal override {
        int24 rangeEnd = deferred.fromTick > deferred.toTick ? deferred.fromTick : deferred.toTick;
        // Bounded ticks per call (re-defers remaining range automatically).
        // Unbounded maxOrders so any individual tick can always be fully processed,
        // avoiding infinite re-deferral when a single tick exceeds maximumExecutionCount.
        _collectAndProcessOrders(
            key,
            deferred.cursorTick,
            rangeEnd,
            deferred.fromTick,
            deferred.toTick,
            currentTick,
            sqrtPriceX96,
            maxTicksPerSwapCallback,
            type(uint256).max
        );
    }

    function _settleOrder(PoolId poolId, uint32 orderId, BalanceDelta delta) internal {
        Order memory order = pendingOrders[poolId][orderId];

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        (uint128 remainingAmount, uint128 tradedAmount) =
            order.zeroForOne ? (uint128(amount0), uint128(amount1)) : (uint128(amount1), uint128(amount0));

        if (remainingAmount == 0) {
            emit OrderFilled(poolId, orderId, tradedAmount);
        } else {
            emit OrderCancelled(poolId, orderId, remainingAmount, tradedAmount);
        }

        delete pendingOrders[poolId][orderId];
    }

    function createOrder(CreateOrderParams calldata params) external returns (uint32 orderId) {
        PoolId poolId = params.poolKey.toId();

        if (!poolWhitelist[poolId]) {
            revert PoolNotWhitelisted(poolId);
        }

        if (!hasRole(Roles.V4_HOOK_ROLE, address(params.poolKey.hooks))) {
            revert PoolNotSupported(poolId);
        }

        address tokenIn = Currency.unwrap(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1);

        OrderValidation.validateMinimumAmount(params.amountIn, _minimumOrderAmount[tokenIn]);

        OrderValidation.validateTickRange(
            params.tickLower, params.tickUpper, params.poolKey.tickSpacing, params.enablePartialFill
        );

        /**
         * Scenario: zeroForOne order, 0 -> 1
         * The order is waiting for taker to buy token0. The order may be filled after the tick moves up.
         * tickThreshold = tickUpper (order fills when price moves above the range)
         *   |
         * -t+2- )-| (tick upper = threshold) - order filled if tick moved to here
         *   |     | user-specified tick range
         * -t+1- )-| (tick lower)
         *   |
         * -t+0- current tick
         *
         * Scenario: oneForZero order, 1 -> 0
         * The order is waiting for taker to buy token1. The order may be filled after the tick moves down.
         * tickThreshold = tickLower (order fills when price moves below the range)
         * -t+0- current tick
         *   |
         * -t-1- )-| (tick upper)
         *   |     | user-specified tick range
         * -t-2- )-| (tick lower = threshold) - order filled if tick moved to here
         *   |
         */
        // Get the current tick directly from slot0 instead of calculating from sqrtPriceX96
        // This avoids the Uniswap edge case where TickMath.getTickAtSqrtPrice() may be off by one
        // when the pool adjusts currentTick = tickNext - 1 at exact tick boundaries
        (, int24 tick,,) = poolManager.getSlot0(params.poolKey.toId());

        OrderValidation.validateTickThreshold(tick, params.tickLower, params.tickUpper, params.zeroForOne);

        uint256 liquidity;

        if (params.zeroForOne) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                params.amountIn
            );
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(params.tickLower),
                TickMath.getSqrtPriceAtTick(params.tickUpper),
                params.amountIn
            );
        }

        OrderBook storage orderBook = _orderBooks[poolId];

        if (orderBook.tickSpacing == 0) {
            orderBook.initialize(params.poolKey.tickSpacing);
        }

        orderId = orderBook.getNextOrderId();

        if (pendingOrders[poolId][orderId].owner != address(0)) {
            emit OrderIdCollisionDetected(poolId, orderId);
            revert OrderIdCollision(orderId);
        }

        ModifyLiquidityParams memory modifyLiquidityParams =
            _makeModifyLiquidityParams(params.tickLower, params.tickUpper, liquidity.toInt256(), orderId);

        ModifyLiquidityPayload memory payload =
            ModifyLiquidityPayload(params.poolKey, modifyLiquidityParams, new bytes(0), msg.sender, address(this));

        poolManager.unlock(abi.encode(ActionType.ModifyLiquidity, abi.encode(payload)));

        Order memory newOrder = Order(
            msg.sender, params.zeroForOne, params.tickLower, params.tickUpper, liquidity, params.enablePartialFill
        );

        pendingOrders[poolId][orderId] = newOrder;

        // to perform partial fill, we need to push the order to the tickLower and tickUpper
        // otherwise, we push the order to the tickThreshold (tickLower or tickUpper) only
        if (params.enablePartialFill) {
            _pushOrderCapped(orderBook, newOrder.partialThresholdLower(params.poolKey.tickSpacing), orderId);
            _pushOrderCapped(orderBook, newOrder.partialThresholdUpper(params.poolKey.tickSpacing), orderId);
        } else {
            _pushOrderCapped(orderBook, newOrder.fulfillThreshold(), orderId);
        }

        emit OrderCreated(
            poolId,
            orderId,
            msg.sender,
            params.tickLower,
            params.tickUpper,
            params.amountIn,
            params.zeroForOne,
            params.enablePartialFill,
            liquidity
        );
    }

    function cancelOrder(CancelOrderParams calldata params) external {
        PoolId poolId = params.poolKey.toId();
        Order memory order = pendingOrders[poolId][params.orderId];

        if (order.owner != msg.sender && !hasRole(Roles.ORDER_RESOLVER_ROLE, msg.sender)) {
            revert Unauthorized();
        }

        ModifyLiquidityParams memory modifyLiquidityParams =
            _makeModifyLiquidityParams(order.tickLower, order.tickUpper, -order.liquidity.toInt256(), params.orderId);

        ModifyLiquidityPayload memory payload =
            ModifyLiquidityPayload(params.poolKey, modifyLiquidityParams, new bytes(0), address(0), order.owner);

        // no payer is required for remove liquidity
        bytes memory result = poolManager.unlock(abi.encode(ActionType.ModifyLiquidity, abi.encode(payload)));

        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        delta.validateMinOut(params.amount0Min, params.amount1Min);

        _settleOrder(poolId, params.orderId, delta);

        // Remove order from pool state to prevent it from being fulfilled
        OrderBook storage orderBook = _orderBooks[poolId];
        if (order.enablePartialFill) {
            orderBook.removeOrder(order.partialThresholdLower(params.poolKey.tickSpacing), params.orderId);
            orderBook.removeOrder(order.partialThresholdUpper(params.poolKey.tickSpacing), params.orderId);
        } else {
            orderBook.removeOrder(order.fulfillThreshold(), params.orderId);
        }
    }

    function ordersAtTick(PoolId poolId, int24 tick) external view returns (uint32) {
        return _orderBooks[poolId].orderCounts[tick];
    }

    function pendingOrder(PoolId poolId, uint32 orderId) external view returns (Order memory) {
        return pendingOrders[poolId][orderId];
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            // Casting from uint256 to uint160 is safe due to limits on the total supply of a pool
            _permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    function _executeOrders(
        PoolKey memory key,
        PackedOrderId[] memory packedOrderIds,
        int24 fromTick,
        int24 toTick,
        BatchBounds memory batch,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal override {
        PoolId poolId = key.toId();

        OrderBook storage orderBook = _orderBooks[poolId];

        int24 adjustedToTick = toTick;
        bool shouldExecute = true;

        // it may happen when defer execution is called, the `toTick` is not the current tick
        // if `toTick` is not the current tick, we need to adjust the `adjustedToTick` or invalid the execution
        if (currentTick != toTick) {
            if (fromTick < toTick) {
                if (currentTick <= fromTick) {
                    // tick has ran out of range
                    shouldExecute = false;
                } else {
                    adjustedToTick = currentTick;
                }
            } else if (fromTick > toTick) {
                if (currentTick >= fromTick) {
                    // tick has ran out of range
                    shouldExecute = false;
                } else {
                    adjustedToTick = currentTick;
                }
            }
        }

        TransientUint32Set.Set executingOrders =
            TransientUint32Set.wrap(keccak256(abi.encodePacked("ExecutingOrders", _orderExecutionNonce)));

        unchecked {
            _orderExecutionNonce += 1;
        }

        for (uint256 i = 0; i < packedOrderIds.length; i++) {
            PackedOrderId packed = packedOrderIds[i];
            uint256 count = packed.countOrders();

            for (uint256 j = 0; j < count; j++) {
                uint32 orderId = packed.unpack(j);

                Order memory order = pendingOrders[poolId][orderId];

                if (!executingOrders.add(orderId) || order.liquidity == 0) {
                    continue;
                }

                bool executed =
                    shouldExecute && _executeOrder(key, orderId, order, fromTick, adjustedToTick, sqrtPriceX96);

                if (!executed) {
                    _requeueUnexecuted(orderBook, order, orderId, key.tickSpacing, batch);
                }
            }
        }

        // all fees are settled to the fee recipient
        _safeTakeOrSettleAll(key.currency0, feeRecipient, address(0));
        _safeTakeOrSettleAll(key.currency1, feeRecipient, address(0));
    }

    // @dev the `toTick` should always be the current tick
    function _executeOrder(
        PoolKey memory key,
        uint32 orderId,
        Order memory order,
        int24 fromTick,
        int24 toTick,
        uint160 sqrtPriceX96
    ) internal returns (bool executed) {
        // zero for one order will only be filled if the tick moves up
        // one for zero order will only be filled if the tick moves down
        if (order.zeroForOne == fromTick < toTick) {
            (int24 fulfillThreshold, int24 partialFillThreshold) = order.zeroForOne
                ? (order.tickUpper, order.tickLower + key.tickSpacing)
                : (order.tickLower, order.tickUpper - key.tickSpacing);

            // orders are only fulfilled if the tick moves across the fulfillThreshold
            bool isFulfilled = _isTickInRange(fulfillThreshold, fromTick, toTick);

            if (isFulfilled) {
                _fulfillOrder(key, orderId, order);
                return true;
            }

            if (order.enablePartialFill) {
                bool isPartiallyFilled = _isTickInRange(partialFillThreshold, fromTick, toTick);

                if (isPartiallyFilled) {
                    (PartialFillResult fillResult, Order memory newOrder) =
                        _partialFillOrder(key, orderId, toTick, sqrtPriceX96);

                    if (fillResult == PartialFillResult.NotFilled) {
                        return false;
                    }

                    OrderBook storage orderBook = _orderBooks[key.toId()];

                    // remove the order from the fulfillThreshold tick (the other tick not crossed by moveTick)
                    orderBook.removeOrder(fulfillThreshold, orderId);

                    if (fillResult == PartialFillResult.NewOrderCreated) {
                        int24 thresholdLower = newOrder.partialThresholdLower(key.tickSpacing);
                        int24 thresholdUpper = newOrder.partialThresholdUpper(key.tickSpacing);

                        // threshold may be the same if tick range is only 1 tick
                        if (thresholdLower != thresholdUpper) {
                            orderBook.pushOrder(thresholdLower, orderId);
                        }

                        orderBook.pushOrder(thresholdUpper, orderId);
                    }

                    return true;
                }
            }
        }

        return false;
    }

    function _fulfillOrder(PoolKey memory key, uint32 orderId, Order memory order) internal {
        ModifyLiquidityParams memory params =
            _makeModifyLiquidityParams(order.tickLower, order.tickUpper, -order.liquidity.toInt256(), orderId);

        (BalanceDelta callerDelta, BalanceDelta feesDelta) = poolManager.modifyLiquidity(key, params, new bytes(0));

        BalanceDelta principalDelta = callerDelta - feesDelta;

        _settleOrder(key.toId(), orderId, principalDelta);

        int128 amount0 = principalDelta.amount0();
        int128 amount1 = principalDelta.amount1();

        // principal delta is always expected to be positive here
        _safeTakeOrSettle(key.currency0, amount0, order.owner, address(0));
        _safeTakeOrSettle(key.currency1, amount1, order.owner, address(0));
    }

    ///  The _partialFillOrder function handles orders that have been partially filled when the current tick price moves into their specified range but doesn't fully cross it.
    ///
    ///  How It Works:
    ///
    ///  1. Tick Range Calculation:
    ///
    ///  2. For zeroForOne orders (selling token0 for token1):
    ///  - Original order waits for price to move UP (tick increases)
    ///  - When current tick enters the order's range from below:
    ///      - tickLower = next tick above current tick (aligned to tick spacing)
    ///      - tickUpper = original order's upper bound
    ///  - This creates a narrowed range from current position to original upper bound
    ///
    ///  For oneForZero orders (selling token1 for token0):
    ///  - Original order waits for price to move DOWN (tick decreases)
    ///  - When current tick enters the order's range from above:
    ///      - tickLower = original order's lower bound
    ///      - tickUpper = current tick (aligned to tick spacing)
    ///  - This creates a narrowed range from original lower bound to current position
    ///  3. Liquidity Removal:
    ///  - Removes all liquidity from the original order position
    ///  - Calculates the amounts of token0 and token1 received
    ///  4. Settlement and Recreation:
    ///  - Settles the output token to the order owner
    ///  - Uses the unsettled input token amount to create a new partial order
    ///  - The new order has the adjusted tick range calculated in step 2
    ///
    ///  Visual Scenario:
    ///
    ///  ZeroForOne Partial Fill Example:
    ///  Initial Order State:
    ///    |
    ///  -t+3- )-| tickUpper (original)
    ///    |     | Original order range
    ///  -t+2- )-|
    ///    |     |
    ///  -t+1- )-| tickLower (original)
    ///    |
    ///  -t+0- Initial tick position
    ///
    ///  After tick moves to t+2:
    ///    |
    ///  -t+3- )-| tickUpper (remains same)
    ///    |     | New partial order range
    ///  -t+2- )-| tickLower (new) = current tick + spacing
    ///    |
    ///        [Partial fill occurred here]
    ///
    ///  OneForZero Partial Fill Example:
    ///  Initial Order State:
    ///  -t+0- Initial tick position
    ///    |
    ///  -t-1- )-| tickUpper (original)
    ///    |     | Original order range
    ///  -t-2- )-|
    ///    |     |
    ///  -t-3- )-| tickLower (original)
    ///    |
    ///
    ///  After tick moves to t-2:
    ///    |
    ///  -t-2- )-| tickUpper (new) = current tick
    ///    |     | New partial order range
    ///        [Partial fill occurred here]
    ///    |     |
    ///  -t-3- )-| tickLower (remains same)
    ///    |
    ///
    ///  Key Points:
    ///
    ///  1. Partial fills only occur when enablePartialFill = true - Orders must explicitly opt-in
    ///  2. The function preserves unfilled liquidity by creating a new order with adjusted range
    ///  3. Edge case handling prevents invalid tick ranges at protocol boundaries
    ///  4. The new order maintains the same direction (zeroForOne) as the original
    ///  5. Order ID is reused for the new partial order, maintaining continuity
    function _partialFillOrder(PoolKey memory key, uint32 orderId, int24 currentTick, uint160 sqrtPriceX96)
        internal
        returns (PartialFillResult result, Order memory order)
    {
        PoolId poolId = key.toId();
        order = pendingOrders[poolId][orderId];
        uint256 oldLiquidity = order.liquidity;
        bool zeroForOne = order.zeroForOne;
        int24 oldTickLower = order.tickLower;
        int24 oldTickUpper = order.tickUpper;
        int24 newTickLower;
        int24 newTickUpper;

        // calculate tick range
        if (zeroForOne) {
            newTickLower = (currentTick / key.tickSpacing) * key.tickSpacing;
            newTickUpper = oldTickUpper;

            // Check currentTick (not newTickLower) to determine tick adjustment direction.
            // Solidity's integer division truncates toward zero, which affects tick alignment:
            // - For negative ticks: division rounds UP (e.g., -15/10 = -1, not -2)
            //   This means newTickLower could be ABOVE currentTick, so we subtract tickSpacing to ensure it's below.
            // - For zero/positive ticks: division rounds DOWN naturally, newTickLower is already below currentTick.
            if (currentTick < 0) {
                newTickLower = newTickLower - key.tickSpacing;
            }

            // Early return: no partial fill needed if tick hasn't moved across a full tick boundary.
            // Because full fills are handled first, we don't need to worry about current tick being
            // greater than tickUpper here (for zeroForOne) or less than tickLower (for oneForZero).
            // If the tick had moved far enough to create an invalid range, it would have been
            // fully filled and removed by _fulfillOrder() before reaching _partialFillOrder().
            if (newTickLower == oldTickLower) {
                return (PartialFillResult.NotFilled, order);
            }

            if (newTickLower >= newTickUpper) {
                // no need to check whether newTickLower is lower than minimum usable tick or not.
                // because partial fill order is always created with tick range greater than 1 tick spacing.
                newTickLower = newTickUpper - key.tickSpacing;
            }
        } else {
            newTickLower = oldTickLower;
            newTickUpper = (currentTick / key.tickSpacing) * key.tickSpacing;

            // Check currentTick (not newTickUpper) to determine tick adjustment direction.
            // Solidity's integer division truncates toward zero, which affects tick alignment:
            // - For positive ticks: division rounds DOWN (e.g., 15/10 = 1, not 2)
            //   This means newTickUpper could be BELOW currentTick, so we add tickSpacing to ensure it's above.
            // - For zero/negative ticks: division rounds UP naturally, newTickUpper is already above currentTick.
            if (currentTick > 0) {
                newTickUpper = newTickUpper + key.tickSpacing;
            }

            // refer to early return comment above
            if (newTickUpper == oldTickUpper) {
                return (PartialFillResult.NotFilled, order);
            }

            if (newTickLower >= newTickUpper) {
                // no need to check whether newTickUpper is higher than maximum usable tick or not.
                // because partial fill order is always created with tick range greater than 1 tick spacing.
                newTickUpper = newTickLower + key.tickSpacing;
            }
        }

        ModifyLiquidityParams memory removeParams =
            _makeModifyLiquidityParams(oldTickLower, oldTickUpper, -oldLiquidity.toInt256(), orderId);

        (BalanceDelta removeDelta, BalanceDelta removeFeesDelta) =
            poolManager.modifyLiquidity(key, removeParams, new bytes(0));

        BalanceDelta principalDelta = removeDelta - removeFeesDelta;

        uint128 remainingAmount = zeroForOne ? uint128(principalDelta.amount0()) : uint128(principalDelta.amount1());

        uint128 tradedAmount = zeroForOne ? uint128(principalDelta.amount1()) : uint128(principalDelta.amount0());

        uint256 newLiquidity;

        {
            (uint256 amount0, uint256 amount1) =
                zeroForOne ? (remainingAmount, tradedAmount) : (tradedAmount, remainingAmount);

            newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(newTickLower),
                TickMath.getSqrtPriceAtTick(newTickUpper),
                amount0,
                amount1
            );
        }

        // in general case, liquidity should be positive
        // but in case of dust remaining, check liquidity before recreate the order
        // and settle the order if liquidity is 0, to prevent order status stuck
        if (newLiquidity > 0) {
            result = PartialFillResult.NewOrderCreated;

            ModifyLiquidityParams memory addParams =
                _makeModifyLiquidityParams(newTickLower, newTickUpper, newLiquidity.toInt256(), orderId);

            (BalanceDelta addDelta, BalanceDelta addFeesDelta) =
                poolManager.modifyLiquidity(key, addParams, new bytes(0));

            principalDelta = principalDelta + addDelta - addFeesDelta;

            order.liquidity = newLiquidity;
            order.tickLower = newTickLower;
            order.tickUpper = newTickUpper;

            // update storage
            pendingOrders[poolId][orderId] = order;

            emit OrderPartiallyFilled(
                poolId, orderId, remainingAmount, tradedAmount, newTickLower, newTickUpper, newLiquidity
            );
        } else {
            _settleOrder(poolId, orderId, principalDelta);
            return (PartialFillResult.DustSettled, order);
        }

        {
            int128 amount0 = principalDelta.amount0();
            int128 amount1 = principalDelta.amount1();

            _safeTakeOrSettle(key.currency0, amount0, order.owner, address(this));

            _safeTakeOrSettle(key.currency1, amount1, order.owner, address(this));
        }
    }

    /// @notice Withdraws tokens from the pool manager
    /// @param currency The currency to withdraw
    /// @param amount The amount of tokens to withdraw
    function _withdrawToken(Currency currency, uint256 amount) internal {
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
    }

    /// @notice Safely handles token transfers with blacklist protection
    /// @dev Defers payment if transfer fails due to blacklist or insufficient deposits
    /// @param currency The currency to transfer
    /// @param amount The amount to transfer (positive for take, negative for settle)
    /// @param taker The recipient address
    /// @param payer The payer address (for settle operations)
    function _safeTakeOrSettle(Currency currency, int128 amount, address taker, address payer) internal {
        ResolveResult result = _takeOrSettle(currency, amount, taker, payer);
        _handleDeltaResolveResult(result, int256(amount), currency, taker);
    }

    /// @notice Safely handles full balance transfers with blacklist protection
    /// @dev Defers payment if transfer fails due to blacklist or insufficient deposits
    /// @param currency The currency to transfer
    /// @param taker The recipient address
    /// @param payer The payer address (for settle operations)
    function _safeTakeOrSettleAll(Currency currency, address taker, address payer) internal {
        (ResolveResult result, int256 amount) = _takeOrSettleAll(currency, taker, payer);
        _handleDeltaResolveResult(result, amount, currency, taker);
    }

    function _handleDeltaResolveResult(ResolveResult result, int256 amount, Currency currency, address taker) internal {
        // ignore zero or negative amount
        if (amount <= 0) {
            return;
        }

        if (result == ResolveResult.InsufficientDeposits) {
            _deferPayment(currency, uint256(amount), taker, PaymentDeferredReason.InsufficientFundsTemporarily);
        } else if (result == ResolveResult.TakeFailed) {
            // Handles blacklist scenarios to prevent DoS attacks
            _deferPayment(currency, uint256(amount), taker, PaymentDeferredReason.UnableToTransfer);
        }
    }

    function _makeModifyLiquidityParams(int24 tickLower, int24 tickUpper, int256 liquidity, uint32 orderId)
        internal
        pure
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: bytes32(uint256(orderId))
        });
    }

    function _isTickInRange(int24 tick, int24 fromTick, int24 toTick) internal pure returns (bool) {
        return fromTick < toTick ? (fromTick <= tick && tick <= toTick) : (toTick < tick && tick <= fromTick);
    }

    /// @dev Enforce the per-tick order cap at user entry. Only used by
    ///      `createOrder` — partial-fill sub-order creation and requeue paths
    ///      deliberately call `orderBook.pushOrder` directly so the cap cannot
    ///      brick a swap callback when a partially-filled order lands on a tick
    ///      that happens to be at capacity.
    function _pushOrderCapped(OrderBook storage orderBook, int24 tick, uint32 orderId) internal {
        if (orderBook.orderCounts[tick] >= MAX_ORDERS_PER_TICK) {
            revert TickOrderCapReached(tick);
        }
        orderBook.pushOrder(tick, orderId);
    }

    /// @dev Requeue an order whose `_executeOrder()` returned false. For
    ///      partial-fill orders each threshold is gated on `batch` because
    ///      bounded `moveTick()` may have left one of them alive. For
    ///      non-partial-fill orders the single threshold is always safe to
    ///      requeue: the order reached this point only because its tick was
    ///      extracted, which means `moveTick()` deleted it.
    function _requeueUnexecuted(
        OrderBook storage orderBook,
        Order memory order,
        uint32 orderId,
        int24 tickSpacing,
        BatchBounds memory batch
    ) internal {
        if (order.enablePartialFill) {
            int24 thresholdLower = order.partialThresholdLower(tickSpacing);
            if (_wasProcessedThisBatch(thresholdLower, batch)) {
                orderBook.pushOrder(thresholdLower, orderId);
            }

            int24 thresholdUpper = order.partialThresholdUpper(tickSpacing);
            if (thresholdLower != thresholdUpper && _wasProcessedThisBatch(thresholdUpper, batch)) {
                orderBook.pushOrder(thresholdUpper, orderId);
            }
        } else {
            orderBook.pushOrder(order.fulfillThreshold(), orderId);
        }
    }

    /// @dev True iff `tick` was deleted by the `moveTick()` call described by
    ///      `batch`. Relies on `moveTick()`'s monotonic low→high bitmap walk:
    ///      when anything is deleted, the removed set is every initialized
    ///      tick in `[moveFrom, cursor]` (upward move) or `(moveTo, cursor]`
    ///      (downward move). Since callers only query thresholds of orders
    ///      that appeared in `packedOrderIds`, those ticks are initialized by
    ///      construction and interval membership implies set membership.
    function _wasProcessedThisBatch(int24 tick, BatchBounds memory batch) internal pure returns (bool) {
        return batch.moveFrom < batch.moveTo
            ? (batch.moveFrom <= tick && tick <= batch.cursor)
            : (batch.moveTo < tick && tick <= batch.cursor);
    }
}
