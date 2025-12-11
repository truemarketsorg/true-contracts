// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct Order {
    address owner;
    bool zeroForOne;
    int24 tickLower;
    int24 tickUpper;
    uint256 liquidity;
    bool enablePartialFill;
}

library OrderLibrary {
    function partialThresholdLower(Order memory order, int24 tickSpacing) internal pure returns (int24) {
        return order.zeroForOne ? order.tickLower + tickSpacing : order.tickLower;
    }

    function partialThresholdUpper(Order memory order, int24 tickSpacing) internal pure returns (int24) {
        return order.zeroForOne ? order.tickUpper : order.tickUpper - tickSpacing;
    }

    function fulfillThreshold(Order memory order) internal pure returns (int24) {
        return order.zeroForOne ? order.tickUpper : order.tickLower;
    }
}
