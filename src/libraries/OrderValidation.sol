pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library OrderValidation {
    error InvalidTickRange(int24 tickLower, int24 tickUpper);

    error InvalidTickThreshold(int24 currentTick, int24 tickThreshold, bool zeroForOne);

    error InsufficientOrderAmount(uint128 amountIn, uint8 decimals, uint256 minimumLiteralAmount);

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

    function validateTickThreshold(int24 tick, int24 tickLower, int24 tickUpper, int24 tickThreshold, bool zeroForOne)
        internal
        pure
    {
        if (zeroForOne && tick >= tickLower) {
            revert InvalidTickThreshold(tick, tickThreshold, zeroForOne);
        }

        if (!zeroForOne && tick <= tickUpper) {
            revert InvalidTickThreshold(tick, tickThreshold, zeroForOne);
        }
    }

    function validateMinimumAmount(address token, uint128 amount, uint256 minimumLiteralAmount) internal view {
        if (minimumLiteralAmount == 0) {
            return;
        }

        uint8 decimals = IERC20Metadata(token).decimals();

        uint256 literalAmount = amount / (10 ** decimals);

        if (literalAmount < minimumLiteralAmount) {
            revert InsufficientOrderAmount(amount, decimals, minimumLiteralAmount);
        }
    }
}
