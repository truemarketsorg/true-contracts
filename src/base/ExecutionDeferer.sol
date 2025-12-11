pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PackedOrderId} from "../libraries/PackedOrderId.sol";
import {IOrderManager} from "../interfaces/IOrderManager.sol";
import {OrderManagerState} from "./OrderManagerState.sol";

/// @title ExecutionDeferer
/// @notice Abstract contract for deferring order executions
/// @dev Allows batching large numbers of order executions for later execution
abstract contract ExecutionDeferer is OrderManagerState {
    using StateLibrary for IPoolManager;

    struct DeferredExecution {
        PackedOrderId[] orderIds;
        int24 fromTick;
        int24 toTick;
    }

    /// @notice Maximum number of orders that can be executed in a single batch
    /// @dev Used to split large execution arrays into manageable chunks
    uint256 public maximumExecutionCount = 100;

    /// @notice Nested mapping of deferred executions by pool ID and hash ID
    /// @dev First key is pool ID, second key is hash of the order array
    mapping(PoolId => mapping(bytes32 => DeferredExecution)) public deferredExecutions;

    /// @notice Resolves a batch of deferred order executions
    /// @dev Fulfills the orders and removes them from the deferred mapping
    /// @param key The pool key for the orders to execute
    /// @param hashId The hash identifier of the deferred execution batch
    function _resolveDeferredExecution(PoolKey memory key, bytes32 hashId) internal {
        PoolId poolId = key.toId();

        DeferredExecution memory deferred = deferredExecutions[poolId][hashId];

        // Update state before external calls (checks-effects-interactions pattern)
        delete deferredExecutions[poolId][hashId];

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        _executeOrders(key, deferred.orderIds, deferred.fromTick, deferred.toTick, currentTick, sqrtPriceX96);

        emit IOrderManager.DeferredExecutionResolved(poolId, hashId, deferred.fromTick, deferred.toTick);
    }

    /// @notice Defers order executions by storing them for later execution
    /// @dev Splits large arrays into chunks based on maximumExecutionCount / 8
    /// @param poolId The ID of the pool for these orders
    /// @param packedOrderIds Array of packed order IDs to defer
    function _deferExecution(PoolId poolId, PackedOrderId[] memory packedOrderIds, int24 fromTick, int24 toTick)
        internal
    {
        uint256 count = packedOrderIds.length;
        // a `PackedOrderId` contains 8 ids, so we divide the maximumExecutionCount by 8 to get the batch size
        uint256 batchSize = maximumExecutionCount / 8;

        if (batchSize == 0) {
            batchSize = 1;
        }

        for (uint256 offset = 0; offset < count; offset += batchSize) {
            uint256 subCount = count - offset > batchSize ? batchSize : count - offset;
            PackedOrderId[] memory orderIds = new PackedOrderId[](subCount);

            for (uint256 i = 0; i < subCount; i++) {
                orderIds[i] = packedOrderIds[offset + i];
            }

            DeferredExecution memory deferred = DeferredExecution(orderIds, fromTick, toTick);

            bytes32 hashId = keccak256(abi.encode(deferred));

            // Duplicate hashIds can occur when partial fill is enabled for all orders and tick movement
            // spans their entire tick range. This causes orders to appear twice in `packedOrderIds`,
            // potentially creating identical batches. We skip duplicates since one execution handles all orders.
            if (deferredExecutions[poolId][hashId].orderIds.length > 0) {
                continue;
            }

            deferredExecutions[poolId][hashId] = deferred;

            emit IOrderManager.ExecutionDeferred(poolId, hashId);
        }
    }

    /// @notice Abstract function to execute a batch of orders
    /// @dev Must be implemented by inheriting contracts to define execution logic
    /// @param key The pool key for the orders
    /// @param packedOrderIds Array of packed order IDs to execute
    function _executeOrders(
        PoolKey memory key,
        PackedOrderId[] memory packedOrderIds,
        int24 fromTick,
        int24 toTick,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal virtual;
}
