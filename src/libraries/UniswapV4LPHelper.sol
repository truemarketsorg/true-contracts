// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

library UniswapV4LPHelper {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct TickRange {
        int24 minTick;
        int24 maxTick;
    }

    struct SingleSidedPositionParams {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        bool isToken0PaymentToken;
        address token0;
        address token1;
    }

    error InvalidPrice();
    error InvalidTickRange();
    error TickOutOfBounds();
    error PoolNotInitialized();
    error InvalidLiquidityAmount();
    error InvalidToken();

    /// @notice Returns whether tokenA sorts before tokenB
    function sortsBefore(address tokenA, address tokenB) internal pure returns (bool) {
        return tokenA < tokenB;
    }

    /// @notice Align tick to the nearest usable tick based on tick spacing
    function nearestUsableTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--;
        int24 result = intervals * tickSpacing;

        // Ensure the result is within valid bounds AND properly aligned with tick spacing
        if (result < TickMath.MIN_TICK) {
            // Find the nearest usable tick >= MIN_TICK
            int24 minIntervals = (TickMath.MIN_TICK + tickSpacing - 1) / tickSpacing;
            result = minIntervals * tickSpacing;
        }
        if (result > TickMath.MAX_TICK) {
            // Find the nearest usable tick <= MAX_TICK
            int24 maxIntervals = TickMath.MAX_TICK / tickSpacing;
            result = maxIntervals * tickSpacing;
        }
        return result;
    }

    /// @notice Convert price to sqrtPriceX96
    /// @dev This function is used to convert a price to a sqrtPriceX96 value
    /// @param baseToken The base token of the pool
    /// @param quoteToken The quote token of the pool
    /// @param price The price to convert. unit is 1 bp (1/10000)
    /// @return sqrtPriceX96 The sqrtPriceX96 value
    function priceToSqrtPriceX96(address baseToken, address quoteToken, uint256 price)
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        if (price == 0) revert InvalidPrice();

        bool tokenInverse = !sortsBefore(baseToken, quoteToken);

        // Get token decimals to properly scale price calculations
        uint8 baseDecimals = IERC20Metadata(baseToken).decimals();
        uint8 quoteDecimals = IERC20Metadata(quoteToken).decimals();

        uint256 numerator;
        uint256 denominator;

        // Price represents: 1 baseToken = (price/10000) quoteToken
        // We need to calculate the ratio for Uniswap V4's sqrtPriceX96 = sqrt(token1/token0)
        if (tokenInverse) {
            // baseToken > quoteToken, so in pool: token0=quoteToken, token1=baseToken
            // sqrtPriceX96 = sqrt(baseToken/quoteToken) = sqrt(10000/price)
            numerator = 1 * (10 ** baseDecimals);
            denominator = price * (10 ** quoteDecimals) / 10000;
        } else {
            // baseToken < quoteToken, so in pool: token0=baseToken, token1=quoteToken
            // sqrtPriceX96 = sqrt(quoteToken/baseToken) = sqrt(price/10000)
            numerator = price * (10 ** quoteDecimals) / 10000;
            denominator = 1 * (10 ** baseDecimals);
        }

        // Convert price ratio to Uniswap's sqrtPriceX96 format
        // Add overflow protection for large numerator values
        uint256 scaledNumerator;
        if (numerator > type(uint256).max >> 192) {
            // Scale down both numerator and denominator to prevent overflow
            uint256 scaleFactor = (numerator >> 64) + 1;
            scaledNumerator = (numerator / scaleFactor) << 192;
            denominator = denominator / scaleFactor;
        } else {
            scaledNumerator = numerator << 192;
        }

        sqrtPriceX96 = uint160(Math.sqrt(scaledNumerator / denominator));

        // Handle edge cases for extreme price values
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        } else if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) {
            sqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        }
    }

    /// @notice Convert price to tick
    function priceToTick(address baseToken, address quoteToken, uint256 price, int24 tickSpacing)
        internal
        view
        returns (int24)
    {
        uint160 sqrtPriceX96 = priceToSqrtPriceX96(baseToken, quoteToken, price);

        // Convert sqrtPriceX96 to a tick value and ensure it aligns with allowed tick spacing
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        return nearestUsableTick(tick, tickSpacing);
    }

    /// @notice Calculate tick range for liquidity position by price
    function calculateTickRangeByPrice(
        address baseToken,
        address quoteToken,
        int24 tickSpacing,
        uint256 minPrice,
        uint256 maxPrice
    ) internal view returns (TickRange memory range) {
        bool tokenInverse = !sortsBefore(baseToken, quoteToken);

        int24 tick0;
        if (minPrice == 0) {
            tick0 = nearestUsableTick(tokenInverse ? TickMath.MAX_TICK : TickMath.MIN_TICK, tickSpacing);
        } else {
            tick0 = priceToTick(baseToken, quoteToken, minPrice, tickSpacing);
        }

        int24 tick1 = priceToTick(baseToken, quoteToken, maxPrice, tickSpacing);

        if (tick0 < tick1) {
            range.minTick = tick0;
            range.maxTick = tick1;
        } else {
            range.minTick = tick1;
            range.maxTick = tick0;
        }
    }

    /// @notice Ensure Permit2 approval for a specific token amount
    function ensurePermit2Approval(address token, uint256 amount, IAllowanceTransfer permit2, address spender)
        internal
    {
        // First, ensure the calling contract has approved Permit2 to spend the token
        if (IERC20(token).allowance(address(this), address(permit2)) < amount) {
            IERC20(token).approve(address(permit2), amount);
        }

        // Then, ensure Permit2 has approved spender to spend the amount
        (uint160 currentAllowance, uint48 expiration,) = permit2.allowance(address(this), token, spender);

        // If allowance is insufficient or expired, approve exact amount via Permit2
        if (currentAllowance < amount || expiration < block.timestamp + 1 hours) {
            // Convert to uint160, ensuring it doesn't overflow
            uint160 approvalAmount = amount > type(uint160).max ? type(uint160).max : uint160(amount);

            permit2.approve(
                token,
                spender,
                approvalAmount,
                uint48(block.timestamp + 1 days) // 1 day expiration
            );
        }
    }

    /// @notice Pre-calculate parameters for single-sided position creation
    /// @dev Captures a point-in-time snapshot of slot0 (sqrtPriceX96, currentTick).
    ///      Safe to reuse across multiple MINT_POSITION calls because modifyLiquidity()
    ///      never changes slot0 — only swap() does. Must be re-called if any swap occurs
    ///      between uses.
    /// @return params Pre-calculated position parameters including cached tick bounds and sqrtPriceX96
    function calculateSingleSidedPositionParams(PoolKey memory poolKey, address baseToken, IPoolManager poolManager)
        internal
        view
        returns (SingleSidedPositionParams memory params)
    {
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        // Determine if payment token is token0
        if (baseToken == token0) {
            params.isToken0PaymentToken = false; // base token is token0, so payment token must be token1
        } else if (baseToken == token1) {
            params.isToken0PaymentToken = true; // base token is token1, so payment token must be token0
        } else {
            revert InvalidToken(); // base token not in pool
        }

        params.token0 = token0;
        params.token1 = token1;

        // Calculate tick range (price 0 to 1)
        TickRange memory range = calculateTickRangeByPrice(
            baseToken,
            params.isToken0PaymentToken ? token0 : token1, // paymentToken
            poolKey.tickSpacing,
            0,
            10000 // stand for 100%
        );

        // Get current pool state
        int24 currentTick;
        (params.sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolKey.toId());
        if (params.sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Calculate tick bounds for single-sided position
        if (params.isToken0PaymentToken) {
            // Base token is token1, provide liquidity below current price
            params.tickLower = range.minTick;
            params.tickUpper = nearestUsableTick(currentTick - poolKey.tickSpacing, poolKey.tickSpacing);
        } else {
            // Base token is token0, provide liquidity above current price
            params.tickLower = nearestUsableTick(currentTick + poolKey.tickSpacing, poolKey.tickSpacing);
            params.tickUpper = range.maxTick;
        }

        // Ensure ticks are properly aligned
        params.tickLower = (params.tickLower / poolKey.tickSpacing) * poolKey.tickSpacing;
        params.tickUpper = (params.tickUpper / poolKey.tickSpacing) * poolKey.tickSpacing;

        // Validate tick range
        if (params.tickLower >= params.tickUpper) revert InvalidTickRange();
        if (params.tickLower < TickMath.MIN_TICK || params.tickLower > TickMath.MAX_TICK) revert TickOutOfBounds();
        if (params.tickUpper < TickMath.MIN_TICK || params.tickUpper > TickMath.MAX_TICK) revert TickOutOfBounds();
    }

    /// @notice Create a single-sided liquidity position with pre-calculated parameters
    /// @dev Gas-optimized version that uses pre-calculated params for batch operations
    /// @return tokenId The ID of the created position NFT
    function createSingleSidedPositionWithParams(
        PoolKey memory poolKey,
        uint256 baseTokenAmount,
        SingleSidedPositionParams memory params,
        IPositionManager positionManager,
        IAllowanceTransfer permit2,
        address receiver
    ) internal returns (uint256 tokenId) {
        if (baseTokenAmount == 0) revert InvalidLiquidityAmount();

        // Determine amounts based on token ordering
        uint256 amount0;
        uint256 amount1;

        if (params.isToken0PaymentToken) {
            // Base token is token1
            amount0 = 0;
            amount1 = baseTokenAmount;
        } else {
            // Base token is token0
            amount0 = baseTokenAmount;
            amount1 = 0;
        }

        // Calculate liquidity
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            params.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            amount0,
            amount1
        );

        if (liquidity == 0) revert InvalidLiquidityAmount();

        // Slippage tolerance: 0.5%
        uint256 slippageBps = 50;
        uint256 amount0Max = amount0 * (10000 + slippageBps) / 10000;
        uint256 amount1Max = amount1 * (10000 + slippageBps) / 10000;

        // Ensure Permit2 approvals (use amountMax to cover slippage)
        if (amount0 > 0) {
            ensurePermit2Approval(params.token0, amount0Max, permit2, address(positionManager));
        }
        if (amount1 > 0) {
            ensurePermit2Approval(params.token1, amount1Max, permit2, address(positionManager));
        }

        // Encode actions for V4
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        // Prepare parameters
        bytes[] memory callParams = new bytes[](2);
        callParams[0] = abi.encode(
            poolKey,
            params.tickLower,
            params.tickUpper,
            uint256(liquidity),
            uint128(amount0Max),
            uint128(amount1Max),
            receiver,
            ""
        );
        callParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        // Get the token ID that will be minted
        tokenId = positionManager.nextTokenId();

        // Execute liquidity addition
        uint256 deadline = block.timestamp + 60;
        positionManager.modifyLiquidities(abi.encode(actions, callParams), deadline);
    }

    function initializePool(IPoolManager poolManager, PoolKey memory poolKey, uint256 initialPrice, address quoteToken)
        internal
    {
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        address baseToken = token0 == quoteToken ? token1 : token0;
        uint160 sqrtPriceX96 = priceToSqrtPriceX96(baseToken, quoteToken, initialPrice);
        poolManager.initialize(poolKey, sqrtPriceX96);
    }
}
