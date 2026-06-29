// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {PackedOrderId, PackedOrderIdLibrary} from "./PackedOrderId.sol";

/// @notice Stores and manages limit orders at specific price ticks
/// @dev Uses packed storage for efficient gas usage and tick bitmap for fast traversal
/// @param orders Mapping from tick to packed order IDs (8 orders per PackedOrderId)
/// @param orderCounts Number of orders at each tick
/// @param tickBitmap Bitmap tracking which ticks have orders
/// @param tickSpacing The minimum tick interval for valid order placement
/// @param nextOrderId Counter for generating unique order IDs
struct OrderBook {
    mapping(int24 => PackedOrderId[]) orders;
    mapping(int24 => uint32) orderCounts;
    mapping(int16 => uint256) tickBitmap;
    int24 tickSpacing;
    uint32 nextOrderId;
}

/// @title OrderBook Library
/// @notice Manages limit orders in a tick-based order book structure
/// @dev Implements efficient storage and retrieval of orders using packed IDs and tick bitmaps
library OrderBookLibrary {
    using TickBitmap for mapping(int16 => uint256);
    using PackedOrderIdLibrary for PackedOrderId;

    /// @notice Thrown when operations are attempted on an uninitialized order book
    error OrderBookNotInitialized();
    /// @notice Thrown when attempting to initialize an already initialized order book
    error OrderBookAlreadyInitialized();
    /// @notice Thrown when tick spacing is invalid (must be positive)
    error InvalidTickSpacing();

    /// @notice Initializes the order book with a tick spacing
    /// @dev Can only be called once. Order IDs start from 1 (0 is reserved)
    /// @param self The order book storage reference
    /// @param tickSpacing The minimum tick interval for order placement
    function initialize(OrderBook storage self, int24 tickSpacing) internal {
        if (self.tickSpacing != 0) revert OrderBookAlreadyInitialized();
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        self.tickSpacing = tickSpacing;
        self.nextOrderId = 1; // Start from 1, 0 is reserved
    }

    /// @notice Generates and returns the next unique order ID
    /// @dev Increments the internal counter after returning
    /// @param self The order book storage reference
    /// @return nextId The next available order ID
    function getNextOrderId(OrderBook storage self) internal returns (uint32 nextId) {
        if (self.tickSpacing == 0) revert OrderBookNotInitialized();
        unchecked {
            nextId = self.nextOrderId++;
            // 0 is reserved for the empty order
            if (nextId == 0) {
                nextId = self.nextOrderId++;
            }
        }
    }

    /// @notice Adds a new order at the specified tick threshold
    /// @dev Packs multiple order IDs into single storage slots for gas efficiency
    /// @param self The order book storage reference
    /// @param tickThreshold The tick at which the order should be executed
    /// @param orderId The unique identifier of the order to add
    function pushOrder(OrderBook storage self, int24 tickThreshold, uint32 orderId) internal {
        if (self.tickSpacing == 0) revert OrderBookNotInitialized();

        uint32 count = self.orderCounts[tickThreshold];

        // If this is the first order at this tick, mark it as initialized
        if (count == 0) {
            self.tickBitmap.flipTick(tickThreshold, self.tickSpacing);
        }

        (uint256 slot, uint256 position) = PackedOrderIdLibrary.getSlotAndPosition(count);

        // Expand array if needed
        if (slot >= self.orders[tickThreshold].length) {
            self.orders[tickThreshold].push(PackedOrderIdLibrary.empty());
        }

        // Pack the order ID
        self.orders[tickThreshold][slot] = self.orders[tickThreshold][slot].pack(orderId, position);

        self.orderCounts[tickThreshold] = count + 1;
    }

    /// @notice Removes a specific order from the order book
    /// @dev Uses swap-and-pop pattern to maintain array density without gaps
    /// @param self The order book storage reference
    /// @param tickThreshold The tick where the order is located
    /// @param orderId The unique identifier of the order to remove
    function removeOrder(OrderBook storage self, int24 tickThreshold, uint32 orderId) internal {
        if (self.tickSpacing == 0) revert OrderBookNotInitialized();

        uint32 count = self.orderCounts[tickThreshold];
        if (count == 0) return;

        // Find the order position
        bool found = false;
        uint256 foundIndex = 0;

        for (uint256 i = 0; i < count; i++) {
            (uint256 slot, uint256 position) = PackedOrderIdLibrary.getSlotAndPosition(i);
            uint32 currentId = self.orders[tickThreshold][slot].unpack(position);

            if (currentId == orderId) {
                found = true;
                foundIndex = i;
                break;
            }
        }

        if (!found) return;

        // Move last order to found position if not already last
        if (foundIndex < count - 1) {
            (uint256 foundSlot, uint256 foundPos) = PackedOrderIdLibrary.getSlotAndPosition(foundIndex);
            (uint256 lastSlot, uint256 lastPos) = PackedOrderIdLibrary.getSlotAndPosition(count - 1);

            uint32 lastId = self.orders[tickThreshold][lastSlot].unpack(lastPos);

            // Replace found order with last order
            self.orders[tickThreshold][foundSlot] = self.orders[tickThreshold][foundSlot].pack(lastId, foundPos);

            // Clear the last position
            self.orders[tickThreshold][lastSlot] = self.orders[tickThreshold][lastSlot].clear(lastPos);
        } else {
            // If removing the last order, just clear it
            (uint256 slot, uint256 position) = PackedOrderIdLibrary.getSlotAndPosition(foundIndex);
            self.orders[tickThreshold][slot] = self.orders[tickThreshold][slot].clear(position);
        }

        self.orderCounts[tickThreshold] = count - 1;

        // If this was the last order at this tick, clean up
        if (count == 1) {
            self.tickBitmap.flipTick(tickThreshold, self.tickSpacing);
            delete self.orders[tickThreshold];
        }
    }

    /// @notice Collects and removes orders between two ticks, bounded by tick and order limits
    /// @dev Stops at tick boundaries — never processes a partial tick. Stops when EITHER
    ///      maxTicks initialized ticks have been processed OR the next tick would push
    ///      the total order count above maxOrders. Returns a cursor for resumption.
    ///
    ///      Iteration walks the tick bitmap monotonically low→high and deletes
    ///      every initialized tick it encounters until a bound is hit. As a
    ///      consequence, when `affectedOrderIds.length > 0` the set of deleted
    ///      ticks is exactly every initialized tick in `[fromTick, cursor]` on an
    ///      upward move and `(toTick, cursor]` on a downward move. Callers that
    ///      need to gate requeue-after-failure can rely on this interval instead
    ///      of tracking the removed set explicitly.
    /// @param self The order book storage reference
    /// @param fromTick The starting tick
    /// @param toTick The ending tick
    /// @param maxTicks Maximum number of initialized ticks to process
    /// @param maxOrders Maximum number of orders to collect (stops before exceeding)
    /// @return affectedOrderIds Array of packed order IDs that were affected
    /// @return cursor The last processed tick (used to resume from this point)
    /// @return complete True if the entire range was covered
    function moveTick(OrderBook storage self, int24 fromTick, int24 toTick, uint256 maxTicks, uint256 maxOrders)
        internal
        returns (PackedOrderId[] memory affectedOrderIds, int24 cursor, bool complete)
    {
        if (fromTick == toTick || self.tickSpacing == 0) {
            return (new PackedOrderId[](0), toTick, true);
        }
        if (maxTicks == 0) {
            return (new PackedOrderId[](0), fromTick, false);
        }

        (int24 rangeStart, int24 rangeEnd) = fromTick < toTick ? (fromTick - 1, toTick + 1) : (toTick, fromTick + 1);

        // Pre-pass: count packed slots within budget. `rangeExhausted` must be tracked
        // explicitly; a `ticksToProcess < maxTicks` proxy wrongly reports incomplete when
        // the range happens to contain exactly `maxTicks` initialized ticks.
        uint256 packedCount;
        uint256 ticksToProcess;
        uint256 ordersToProcess;
        bool orderBudgetHit;
        bool rangeExhausted;
        {
            int24 tick = rangeStart;
            while (tick < rangeEnd) {
                (int24 next, bool initialized) =
                    self.tickBitmap.nextInitializedTickWithinOneWord(tick, self.tickSpacing, false);

                if (initialized && next < rangeEnd) {
                    if (ticksToProcess >= maxTicks) break;

                    uint32 tickOrderCount = self.orderCounts[next];
                    if (ordersToProcess + tickOrderCount > maxOrders) {
                        orderBudgetHit = true;
                        // Cursor points at the unprocessed dense tick so the resolver can
                        // retry it unbounded. Overwritten by the copy pass when ticksToProcess > 0.
                        cursor = next;
                        break;
                    }

                    packedCount += PackedOrderIdLibrary.slotCount(tickOrderCount);
                    ordersToProcess += tickOrderCount;
                    ticksToProcess++;
                }

                if (next >= rangeEnd) {
                    rangeExhausted = true;
                    break;
                }
                tick = next;
            }
        }

        if (ticksToProcess == 0) {
            if (orderBudgetHit) {
                return (new PackedOrderId[](0), cursor, false);
            }
            return (new PackedOrderId[](0), rangeExhausted ? toTick : fromTick, rangeExhausted);
        }

        // Copy + delete pass (processes exactly ticksToProcess initialized ticks)
        affectedOrderIds = new PackedOrderId[](packedCount);
        uint256 index;
        {
            int24 tick = rangeStart;
            uint256 ticksDone;
            while (tick < rangeEnd && ticksDone < ticksToProcess) {
                (int24 next, bool initialized) =
                    self.tickBitmap.nextInitializedTickWithinOneWord(tick, self.tickSpacing, false);

                if (initialized && next < rangeEnd) {
                    PackedOrderId[] storage packOrderIds = self.orders[next];
                    uint256 len = PackedOrderIdLibrary.slotCount(self.orderCounts[next]);
                    for (uint256 i = 0; i < len; i++) {
                        affectedOrderIds[index++] = packOrderIds[i];
                    }

                    delete self.orders[next];
                    self.orderCounts[next] = 0;
                    self.tickBitmap.flipTick(next, self.tickSpacing);

                    ticksDone++;
                    cursor = next;
                }

                if (next >= rangeEnd) break;
                tick = next;
            }
        }

        assembly {
            mstore(affectedOrderIds, index)
        }

        // rangeExhausted and orderBudgetHit are mutually exclusive by construction
        // (each is the sole setter before its break), so rangeExhausted alone suffices.
        complete = rangeExhausted;
    }

    /// @notice Counts the total number of orders in a tick range
    /// @dev For upward moves, includes both endpoints. For downward moves, includes fromTick, excludes toTick.
    /// @param self The order book storage reference
    /// @param fromTick The starting tick
    /// @param toTick The ending tick
    /// @return count The total number of individual orders in the range
    function countOrders(OrderBook storage self, int24 fromTick, int24 toTick) internal view returns (uint256 count) {
        if (self.tickSpacing == 0) {
            return 0;
        }

        (fromTick, toTick) = fromTick < toTick ? (fromTick - 1, toTick + 1) : (toTick, fromTick + 1);

        int24 tick = fromTick;
        while (tick < toTick) {
            (int24 next, bool initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(tick, self.tickSpacing, false);

            if (initialized && next < toTick) {
                count += self.orderCounts[next];
            }

            if (next >= toTick) break;
            tick = next;
        }
    }

    /// @notice Counts the number of packed order storage slots in a tick range
    /// @dev For upward moves, includes both endpoints. For downward moves, includes fromTick, excludes toTick.
    ///      Each PackedOrderId can contain up to 8 orders.
    /// @param self The order book storage reference
    /// @param fromTick The starting tick
    /// @param toTick The ending tick
    /// @return count The number of PackedOrderId storage slots needed
    function countPackedOrders(OrderBook storage self, int24 fromTick, int24 toTick)
        internal
        view
        returns (uint256 count)
    {
        if (self.tickSpacing == 0) {
            return 0;
        }

        (fromTick, toTick) = fromTick < toTick ? (fromTick - 1, toTick + 1) : (toTick, fromTick + 1);

        int24 tick = fromTick;
        while (tick < toTick) {
            (int24 next, bool initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(tick, self.tickSpacing, false);

            if (initialized && next < toTick) {
                count += PackedOrderIdLibrary.slotCount(self.orderCounts[next]);
            }

            if (next >= toTick) break;
            tick = next;
        }
    }
}
