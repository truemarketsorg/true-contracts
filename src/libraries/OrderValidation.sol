pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library OrderValidation {
    error InvalidTickRange(int24 tickLower, int24 tickUpper);

    error InvalidTickThreshold(int24 currentTick, int24 tickThreshold, bool zeroForOne);

    error InsufficientOrderAmount(uint128 amountIn, uint256 minimumOrderAmount);

    function validateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing, bool enablePartialFill)
        internal
        pure
    {
        if (tickLower >= tickUpper) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        if (tickLower % tickSpacing != 0) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        if (tickUpper % tickSpacing != 0) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        if ((tickUpper - tickLower) < tickSpacing) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        if (enablePartialFill && (tickUpper - tickLower) <= tickSpacing) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
    }

    function validateTickThreshold(int24 tick, int24 tickLower, int24 tickUpper, bool zeroForOne) internal pure {
        if (zeroForOne && tick >= tickLower) {
            revert InvalidTickThreshold(tick, tickLower, zeroForOne);
        }

        if (!zeroForOne && tick <= tickUpper) {
            revert InvalidTickThreshold(tick, tickUpper, zeroForOne);
        }
    }

    function validateMinimumAmount(uint128 amount, uint256 minimumOrderAmount) internal view {
        if (minimumOrderAmount == 0) {
            return;
        }

        if (amount < minimumOrderAmount) {
            revert InsufficientOrderAmount(amount, minimumOrderAmount);
        }
    }
}
