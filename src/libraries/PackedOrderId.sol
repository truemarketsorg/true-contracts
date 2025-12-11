// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type PackedOrderId is uint256;

library PackedOrderIdLibrary {
    uint256 private constant ORDERS_PER_SLOT = 8;
    uint256 private constant BITS_PER_ORDER = 32;
    uint256 private constant ORDER_MASK = 0xFFFFFFFF;

    function pack(PackedOrderId self, uint32 orderId, uint256 position) internal pure returns (PackedOrderId) {
        require(position < ORDERS_PER_SLOT, "Position out of bounds");
        uint256 shift = position * BITS_PER_ORDER;
        uint256 mask = ~(ORDER_MASK << shift);
        uint256 value = PackedOrderId.unwrap(self);
        return PackedOrderId.wrap((value & mask) | (uint256(orderId) << shift));
    }

    function unpack(PackedOrderId self, uint256 position) internal pure returns (uint32) {
        require(position < ORDERS_PER_SLOT, "Position out of bounds");
        uint256 value = PackedOrderId.unwrap(self);
        return uint32((value >> (position * BITS_PER_ORDER)) & ORDER_MASK);
    }

    function clear(PackedOrderId self, uint256 position) internal pure returns (PackedOrderId) {
        require(position < ORDERS_PER_SLOT, "Position out of bounds");
        uint256 shift = position * BITS_PER_ORDER;
        uint256 mask = ~(ORDER_MASK << shift);
        uint256 value = PackedOrderId.unwrap(self);
        return PackedOrderId.wrap(value & mask);
    }

    function isEmpty(PackedOrderId self) internal pure returns (bool) {
        return PackedOrderId.unwrap(self) == 0;
    }

    function isFull(PackedOrderId self) internal pure returns (bool) {
        uint256 value = PackedOrderId.unwrap(self);
        // Check if all 8 positions have non-zero values
        for (uint256 i = 0; i < ORDERS_PER_SLOT; i++) {
            if (((value >> (i * BITS_PER_ORDER)) & ORDER_MASK) == 0) {
                return false;
            }
        }
        return true;
    }

    function countOrders(PackedOrderId self) internal pure returns (uint256 count) {
        uint256 value = PackedOrderId.unwrap(self);
        for (uint256 i = 0; i < ORDERS_PER_SLOT; i++) {
            if (((value >> (i * BITS_PER_ORDER)) & ORDER_MASK) != 0) {
                count++;
            }
        }
    }

    function countOrders(PackedOrderId[] memory self) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < self.length; i++) {
            count += countOrders(self[i]);
        }
    }

    function findOrder(PackedOrderId self, uint32 orderId) internal pure returns (bool found, uint256 position) {
        uint256 value = PackedOrderId.unwrap(self);
        for (uint256 i = 0; i < ORDERS_PER_SLOT; i++) {
            if (uint32((value >> (i * BITS_PER_ORDER)) & ORDER_MASK) == orderId) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function getSlotAndPosition(uint256 orderIndex) internal pure returns (uint256 slot, uint256 position) {
        slot = orderIndex / ORDERS_PER_SLOT;
        position = orderIndex % ORDERS_PER_SLOT;
    }

    function empty() internal pure returns (PackedOrderId) {
        return PackedOrderId.wrap(0);
    }

    /// @notice Splits an array of packed order IDs based on a maximum order count
    /// @dev Preserves the original order (FIFO). The first array contains packed IDs
    ///      whose cumulative order count does not exceed maxCount. The second array
    ///      contains all remaining packed IDs.
    /// @param orderIds The array of packed order IDs to split
    /// @param maxCount Maximum number of individual orders for the first array
    /// @return first First array with packed IDs (total orders ≤ maxCount)
    /// @return second Second array with remaining packed IDs
    function split(PackedOrderId[] memory orderIds, uint256 maxCount)
        internal
        pure
        returns (PackedOrderId[] memory first, PackedOrderId[] memory second)
    {
        uint256 processedCount = 0;
        uint256 firstPackedCount = 0;
        
        // Count how many packed IDs go to the first array
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 ordersInPacked = countOrders(orderIds[i]);
            if (processedCount + ordersInPacked <= maxCount) {
                firstPackedCount++;
                processedCount += ordersInPacked;
            } else {
                // We've reached the limit, stop counting
                break;
            }
        }
        
        // Create arrays - first is exact size, second contains remaining
        first = new PackedOrderId[](firstPackedCount);
        second = new PackedOrderId[](orderIds.length - firstPackedCount);
        
        // Populate first array
        for (uint256 i = 0; i < firstPackedCount; i++) {
            first[i] = orderIds[i];
        }
        
        // Populate second array
        for (uint256 i = firstPackedCount; i < orderIds.length; i++) {
            second[i - firstPackedCount] = orderIds[i];
        }
        
        return (first, second);
    }
}
