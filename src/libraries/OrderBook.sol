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

    /// @notice Collects and removes all orders between two ticks
    /// @dev Used when price moves to execute all orders in the crossed range
    /// @param self The order book storage reference
    /// @param fromTick The starting tick (exclusive)
    /// @param toTick The ending tick (exclusive)
    /// @return affectedOrderIds Array of packed order IDs that were affected
    function moveTick(OrderBook storage self, int24 fromTick, int24 toTick)
        internal
        returns (PackedOrderId[] memory affectedOrderIds)
    {
        if (fromTick == toTick) {
            return new PackedOrderId[](0);
        }

        // orderbook is not initialized, no orders in the book
        if (self.tickSpacing == 0) {
            return new PackedOrderId[](0);
        }

        // Allocate array for packed order IDs (8 orders per PackedOrderId)
        affectedOrderIds = new PackedOrderId[](countPackedOrders(self, fromTick, toTick));

        // Only orders from fromTick (inclusive) to toTick (exclusive) will be affected.
        // So we need to move fromTick one tick to include orders at the fromTick position.
        (fromTick, toTick) = fromTick < toTick ? (fromTick - 1, toTick) : (toTick, fromTick + 1);

        uint256 index = 0;

        int24 tick = fromTick;
        while (tick < toTick) {
            (int24 next, bool initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(tick, self.tickSpacing, false);

            if (initialized && next < toTick) {
                // Copy all PackedOrderId values at this tick
                PackedOrderId[] storage packOrderIds = self.orders[next];
                uint256 len = packOrderIds.length;
                for (uint256 i = 0; i < len; i++) {
                    affectedOrderIds[index++] = packOrderIds[i];
                }

                // Clear the tick
                delete self.orders[next];
                self.orderCounts[next] = 0;
                self.tickBitmap.flipTick(next, self.tickSpacing);
            }

            if (next >= toTick) break;
            tick = next;
        }

        // Resize array to actual packed count
        assembly {
            mstore(affectedOrderIds, index)
        }
    }

    /// @notice Counts the total number of orders in a tick range
    /// @dev The count includes the `fromTick` but excludes the `toTick`
    /// @param self The order book storage reference
    /// @param fromTick The starting tick (inclusive)
    /// @param toTick The ending tick (exclusive)
    /// @return count The total number of individual orders in the range
    function countOrders(OrderBook storage self, int24 fromTick, int24 toTick) internal view returns (uint256 count) {
        if (self.tickSpacing == 0) {
            return 0;
        }

        (fromTick, toTick) = fromTick < toTick ? (fromTick - 1, toTick) : (toTick, fromTick + 1);

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
    /// @dev The count includes the `fromTick` but excludes the `toTick`. Each PackedOrderId can contain up to 8 orders
    /// @param self The order book storage reference
    /// @param fromTick The starting tick (inclusive)
    /// @param toTick The ending tick (exclusive)
    /// @return count The number of PackedOrderId storage slots needed
    function countPackedOrders(OrderBook storage self, int24 fromTick, int24 toTick)
        internal
        view
        returns (uint256 count)
    {
        if (self.tickSpacing == 0) {
            return 0;
        }

        (fromTick, toTick) = fromTick < toTick ? (fromTick - 1, toTick) : (toTick, fromTick + 1);

        int24 tick = fromTick;
        while (tick < toTick) {
            (int24 next, bool initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(tick, self.tickSpacing, false);

            if (initialized && next < toTick) {
                count += self.orders[next].length;
            }

            if (next >= toTick) break;
            tick = next;
        }
    }
}
