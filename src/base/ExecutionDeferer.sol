pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PackedOrderId} from "../libraries/PackedOrderId.sol";
import {IOrderManager} from "../interfaces/IOrderManager.sol";
import {OrderManagerState} from "./OrderManagerState.sol";

/// @title ExecutionDeferer
/// @notice Abstract contract for deferring order executions via tick-range deferral
/// @dev When a swap crosses a dense order band, only a bounded number of ticks and orders
///      are processed in the swap callback. The remaining tick range is stored for later
///      resolution by an off-chain resolver bot.
abstract contract ExecutionDeferer is OrderManagerState {
    using StateLibrary for IPoolManager;

    struct DeferredTickRange {
        int24 fromTick; // original fromTick (for _executeOrders direction logic)
        int24 cursorTick; // where bounded processing stopped
        int24 toTick; // original toTick destination
    }

    /// @notice The tick interval that one `moveTick()` batch actually deleted.
    /// @dev `moveTick()` walks the bitmap monotonically low→high, so when it
    ///      removes anything, the removed set is every initialized tick in
    ///      `[moveFrom, cursor]` on an upward move or `(moveTo, cursor]` on a
    ///      downward move. Passed into `_executeOrders()` so implementations
    ///      can gate requeue-on-failure on this interval (and so stay safe
    ///      under bounded traversal).
    struct BatchBounds {
        int24 moveFrom;
        int24 moveTo;
        int24 cursor;
    }

    /// @notice Maximum number of orders that can be executed in a single batch
    /// @dev Used as the maxOrders bound for moveTick — the bounded traversal stops
    ///      at tick boundaries before exceeding this count
    uint256 public maximumExecutionCount = 100;

    /// @notice Nested mapping of deferred tick ranges by pool ID and hash ID
    /// @dev Stores tick ranges that were not fully processed during a swap callback
    mapping(PoolId => mapping(bytes32 => DeferredTickRange)) public deferredTickRanges;

    /// @notice Maximum initialized ticks processed per swap callback
    /// @dev Bounds the gas cost of moveTick inside the hook's _afterSwap
    uint256 public maxTicksPerSwapCallback = 20;

    /// @notice Defers a tick range for later processing by a resolver
    /// @dev Called when moveTick's bounded traversal doesn't cover the full range
    /// @param poolId The ID of the pool
    /// @param fromTick The original fromTick of the move
    /// @param cursorTick Where bounded processing stopped
    /// @param toTick The original toTick of the move
    function _deferTickRange(PoolId poolId, int24 fromTick, int24 cursorTick, int24 toTick) internal {
        DeferredTickRange memory deferred = DeferredTickRange(fromTick, cursorTick, toTick);
        bytes32 hashId = keccak256(abi.encode(poolId, deferred));
        deferredTickRanges[poolId][hashId] = deferred;
        emit IOrderManager.TickRangeDeferred(poolId, hashId, cursorTick, toTick);
    }

    /// @notice Resolves a deferred tick range by delegating to _processTickRange
    /// @param key The pool key
    /// @param hashId The hash identifier of the deferred tick range
    function _handleDeferredTickRange(PoolKey memory key, bytes32 hashId) internal {
        PoolId poolId = key.toId();

        DeferredTickRange memory deferred = deferredTickRanges[poolId][hashId];
        delete deferredTickRanges[poolId][hashId];

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        _processTickRange(key, deferred, currentTick, sqrtPriceX96);

        emit IOrderManager.DeferredTickRangeResolved(poolId, hashId, deferred.cursorTick, deferred.toTick);
    }

    /// @notice Abstract function to process a deferred tick range
    /// @dev Must be implemented by inheriting contracts to define tick-range processing
    function _processTickRange(
        PoolKey memory key,
        DeferredTickRange memory deferred,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal virtual;

    /// @notice Abstract function to execute a batch of orders
    /// @dev Must be implemented by inheriting contracts to define execution
    ///      logic. `batch` describes the tick interval that the current
    ///      `moveTick()` call actually deleted — implementations must gate any
    ///      requeue-on-failure on `batch`, not on the original (fromTick,
    ///      toTick) range, because bounded traversal can leave later
    ///      thresholds alive and requeueing them would duplicate entries.
    function _executeOrders(
        PoolKey memory key,
        PackedOrderId[] memory packedOrderIds,
        int24 fromTick,
        int24 toTick,
        BatchBounds memory batch,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal virtual;
}
