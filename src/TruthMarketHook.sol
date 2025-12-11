pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOrderManager} from "./interfaces/IOrderManager.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {ISwapValidator} from "./interfaces/ISwapValidator.sol";
import {TransientSlot} from "./libraries/TransientSlot.sol";
import {Roles} from "./libraries/Roles.sol";

contract TruthMarketHook is BaseHook, AccessControl {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientSlot for TransientSlot.Int256Slot;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 private constant PREVIOUS_TICK_SLOT = keccak256("org.truemarkets.hook.previous-tick");

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public feeNumerator = 0; // Default 0%, set to 36 for 0.36%

    IOrderManager public orderManager;
    address public feeCollector;
    ISwapValidator public swapValidator;

    // Errors ////////////////////////////////////////////////////////

    error InvalidRecipient();
    error FeeAmountTooLarge();

    // Events ////////////////////////////////////////////////////////

    event FeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event FeeRateUpdated(uint256 oldRate, uint256 newRate);
    event SettleOrderFailed(PoolId poolId, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt);
    event SwapValidatorUpdated(address indexed oldValidator, address indexed newValidator);
    event OrderManagerUpdated(address indexed oldManager, address indexed newManager);

    constructor(IPoolManager _poolManager, IOrderManager _orderManager, address _feeCollector, address _admin)
        BaseHook(_poolManager)
    {
        orderManager = _orderManager;
        feeCollector = _feeCollector;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get the current tick directly from slot0 instead of calculating from sqrtPriceX96
        // This accounts for Uniswap's tick adjustment behavior where the pool may set
        // currentTick = tickNext - 1 when sqrtPriceX96 == sqrtPriceNextX96 and zeroForOne = true
        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        TransientSlot.Int256Slot slot = TransientSlot.asInt256(PREVIOUS_TICK_SLOT);
        slot.tstore(int256(tick));

        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Validate swap first if validator is set
        if (address(swapValidator) != address(0)) {
            swapValidator.validateAfterSwap(sender, key, params, delta, hookData);
        }

        TransientSlot.Int256Slot slot = TransientSlot.asInt256(PREVIOUS_TICK_SLOT);
        int24 fromTick = int24(slot.tload());

        // Get the post-swap tick directly from slot0 instead of calculating from sqrtPriceX96
        // This ensures we use the actual tick value that Uniswap has set, accounting for the
        // edge case where tick may be adjusted by -1 when the swap ends exactly at a tick boundary
        (uint160 sqrtPriceX96, int24 toTick,,) = poolManager.getSlot0(key.toId());

        orderManager.movePoolTick(key, fromTick, toTick, sqrtPriceX96);

        if (feeNumerator == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // For exactOut (positive amount): specified token is output
        // For exactIn (negative amount): specified token is input
        bool isCurrency0Specified = params.amountSpecified > 0 ? !params.zeroForOne : params.zeroForOne;

        (Currency currencyUnspecified, int128 amountUnspecified) =
            (isCurrency0Specified) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        if (amountUnspecified < 0) amountUnspecified = -amountUnspecified;

        uint256 feeAmount = Math.mulDiv(uint256(int256(amountUnspecified)), feeNumerator, FEE_DENOMINATOR);

        if (feeAmount > 0) {
            poolManager.mint(feeCollector, currencyUnspecified.toId(), feeAmount);

            // Track fee by pool in the fee collection contract
            IFeeCollector(feeCollector).trackPoolFee(key.toId(), currencyUnspecified, feeAmount);

            emit FeeCollected(key.toId(), currencyUnspecified, feeAmount);
        }

        // Validate fee amount fits in int128 before conversion
        if (feeAmount > uint256(uint128(type(int128).max))) {
            revert FeeAmountTooLarge();
        }

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    // Admin functions ////////////////////////////////////////////////

    /// @notice Set the fee collector contract address
    /// @param newCollector The new fee collector contract address
    function setFeeCollector(address newCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCollector == address(0)) revert InvalidRecipient();
        address oldCollector = feeCollector;
        feeCollector = newCollector;
        emit FeeCollectorUpdated(oldCollector, newCollector);
    }

    /// @notice Set the fee rate numerator
    /// @param newNumerator The new fee numerator (36 = 0.36%)
    function setFeeRate(uint256 newNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldRate = feeNumerator;
        feeNumerator = newNumerator;
        emit FeeRateUpdated(oldRate, newNumerator);
    }

    /// @notice Set the swap validator contract
    /// @param _swapValidator The address of the swap validator (or zero to disable)
    function setSwapValidator(address _swapValidator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldValidator = address(swapValidator);
        swapValidator = ISwapValidator(_swapValidator);
        emit SwapValidatorUpdated(oldValidator, _swapValidator);
    }

    /// @notice Set the order manager contract
    /// @param _orderManager The address of the order manager
    function setOrderManager(address _orderManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_orderManager == address(0)) revert InvalidRecipient();
        address oldManager = address(orderManager);
        orderManager = IOrderManager(_orderManager);
        emit OrderManagerUpdated(oldManager, _orderManager);
    }
}
