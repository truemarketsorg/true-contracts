// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/ILauncher.sol";
import "./interfaces/ILaunchpadViewer.sol";
import "./interfaces/ISwapValidator.sol";
import "./interfaces/ITruthMarketHook.sol";
import "./interfaces/ITruthMarketV2.sol";
import "./TruthMarketManager.sol";
import "./libraries/Roles.sol";
import "./libraries/UniswapV4LPHelper.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import "./interfaces/IOrderManager.sol";
import "./interfaces/IPausablePool.sol";
import "./types/LaunchpadTruthMarketV2.sol";

/// @title TruthMarketV2Launcher
/// @notice Launcher implementation for deploying TruthMarketV2 instances via TruthMarketManager
/// @dev Decodes TruthMarketV2Params and delegates market creation to the manager
/// @dev Only addresses with OPERATOR_ROLE (launchpad) can call launch() to ensure proper governance
contract TruthMarketV2Launcher is
    ILauncher,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using PoolIdLibrary for PoolKey;

    /// @notice The TruthMarketManager instance that will create markets
    TruthMarketManager public marketManager;

    IPoolManager public poolManager;

    /// @notice The OrderManager contract for pool whitelisting
    address public orderManager;

    /// @notice Error thrown when invalid arguments are provided
    error InvalidArguments();

    /// @notice Error thrown when swap boundaries are not initialized for a pool
    error BoundariesNotInitialized();

    /// @notice Error thrown when the YES/NO pools do not share a single pause-capable hook
    /// @dev Deferred-settlement safety requires both pools to be pauseable via the same hook
    ///      between launch() and finalize(). A zero hook or mismatched hooks is unsafe.
    error InvalidHookConfiguration();

    /// @notice Emitted when order manager is updated
    event OrderManagerUpdated(address indexed orderManager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the launcher with a reference to the market manager
    /// @param _marketManager Address of the TruthMarketManager contract
    function initialize(address _marketManager, address _poolManager) public initializer {
        if (_marketManager == address(0) || _poolManager == address(0)) revert InvalidArguments();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        marketManager = TruthMarketManager(_marketManager);

        poolManager = IPoolManager(_poolManager);

        // Grant deployer the DEFAULT_ADMIN_ROLE
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Launches a new TruthMarketV2 instance
    /// @dev Decodes params into TruthMarketV2Params and calls marketManager.createMarketV2()
    /// @dev Only callable by addresses with OPERATOR_ROLE (typically the launchpad contract)
    /// @param params ABI-encoded TruthMarketV2Params structure
    /// @return market The address of the newly created market
    function launch(ILaunchpadViewer viewer, uint256 proposalId, bytes calldata params)
        external
        override
        onlyRole(Roles.OPERATOR_ROLE)
        returns (address market)
    {
        // Decode the parameters
        TruthMarketV2Params memory marketParams = abi.decode(params, (TruthMarketV2Params));

        // Call the market manager to create the market
        // TruthMarketManager emits MarketCreatedWithDescription event
        // Pin the market's payment token to the launchpad's own paymentToken so that
        // a subsequent TruthMarketManager.setAddresses() rotation cannot desync the
        // launchpad's escrowed deposits from the market that consumes them.
        address creator = viewer.proposalCreator(proposalId);
        address paymentToken = viewer.paymentToken();
        market = marketManager.createMarketV2(
            marketParams.question,
            marketParams.source,
            marketParams.additionalInfo,
            marketParams.endOfTrading,
            type(uint256).max,
            marketParams.rewardToken,
            marketParams.rewardAmount,
            marketParams.outcomeSymbolYes,
            marketParams.outcomeSymbolNo,
            marketParams.fee,
            marketParams.tickSpacing,
            creator,
            paymentToken
        );

        ITruthMarketV2 marketV2 = ITruthMarketV2(market);

        (PoolKey memory yesPoolKey, PoolKey memory noPoolKey) = marketV2.getPoolKeys();

        uint256 totalDeposits = viewer.proposalTotalDeposits(proposalId);
        uint256 yesDeposits = viewer.proposalOutcomeDeposits(proposalId, 1);
        uint256 noDeposits = viewer.proposalOutcomeDeposits(proposalId, 2);

        UniswapV4LPHelper.initializePool(poolManager, yesPoolKey, (yesDeposits * 10000) / totalDeposits, paymentToken);
        UniswapV4LPHelper.initializePool(poolManager, noPoolKey, (noDeposits * 10000) / totalDeposits, paymentToken);

        _initializeSwapBoundaries(yesPoolKey, paymentToken);
        _initializeSwapBoundaries(noPoolKey, paymentToken);

        PoolId yesPoolId = yesPoolKey.toId();
        PoolId noPoolId = noPoolKey.toId();

        // Pause pools until distribution completes (prevents tick manipulation).
        // The deferred-settlement design requires the pools to remain inert from launch
        // through distribution, so a pause-capable hook is mandatory — a missing or
        // inconsistent hook would leave the market interactive while depositors are
        // still unpaid.
        address yesHook = address(yesPoolKey.hooks);
        address noHook = address(noPoolKey.hooks);
        if (yesHook == address(0) || yesHook != noHook) revert InvalidHookConfiguration();
        IPausablePool(yesHook).pausePool(yesPoolId);
        IPausablePool(yesHook).pausePool(noPoolId);

        // Note: Pool whitelisting is deferred to finalize() after distribution
    }

    /// @notice Finalizes a launched market by unpausing pools and enabling trading
    /// @dev Only callable by addresses with OPERATOR_ROLE (typically the launchpad contract)
    /// @dev Should be called after distribution completes successfully
    /// @param market The address of the market to finalize
    function finalize(address market) external override onlyRole(Roles.OPERATOR_ROLE) nonReentrant {
        ITruthMarketV2 marketV2 = ITruthMarketV2(market);
        (PoolKey memory yesPoolKey, PoolKey memory noPoolKey) = marketV2.getPoolKeys();

        PoolId yesPoolId = yesPoolKey.toId();
        PoolId noPoolId = noPoolKey.toId();

        // Hook address is obtained dynamically from PoolKey to support different hook versions
        // Note: YES and NO pools always use the same hook in TruthMarketV2
        address yesHook = address(yesPoolKey.hooks);
        address noHook = address(noPoolKey.hooks);

        // Fail-closed: ensure swap boundaries were initialized before enabling trading
        if (yesHook != address(0)) {
            address validator = address(ITruthMarketHook(yesHook).swapValidator());
            if (validator != address(0)) {
                (,, bool yesSet) = ISwapValidator(validator).poolBoundaries(yesPoolId);
                (,, bool noSet) = ISwapValidator(validator).poolBoundaries(noPoolId);
                if (!yesSet || !noSet) revert BoundariesNotInitialized();
            }
        }

        // Unpause pools to enable trading
        if (yesHook != address(0) && yesHook == noHook) {
            IPausablePool(yesHook).unpausePool(yesPoolId);
            IPausablePool(yesHook).unpausePool(noPoolId);
        }

        // Whitelist pools in OrderManager if configured
        if (orderManager != address(0)) {
            IOrderManager(orderManager).setPoolWhitelist(yesPoolId, true);
            IOrderManager(orderManager).setPoolWhitelist(noPoolId, true);
        }
    }

    /// @notice Sets the OrderManager contract address for pool whitelisting
    /// @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
    /// @param _orderManager The address of the OrderManager contract
    function setOrderManager(address _orderManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        orderManager = _orderManager;
        emit OrderManagerUpdated(_orderManager);
    }

    /// @notice Returns the minimum trading duration from the market manager
    /// @return The minimum trading duration in seconds
    function minimumTradingDuration() external view override returns (uint256) {
        return marketManager.minimumTradingDuration();
    }

    /// @notice Initializes swap boundaries for a pool via the hook's swap validator
    /// @dev Silently returns if hook or validator is not configured (graceful degradation).
    ///      Requires OPERATOR_ROLE on the swap validator to be granted to this contract.
    /// @param poolKey The pool key to initialize boundaries for
    /// @param _paymentToken The payment token address for the market
    function _initializeSwapBoundaries(PoolKey memory poolKey, address _paymentToken) internal {
        address hookAddr = address(poolKey.hooks);
        if (hookAddr == address(0)) return;

        ISwapValidator validator = ITruthMarketHook(hookAddr).swapValidator();
        if (address(validator) == address(0)) return;

        // Determine which currency is the outcome token
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        address outcomeToken = token0 == _paymentToken ? token1 : token0;

        UniswapV4LPHelper.TickRange memory range = UniswapV4LPHelper.calculateTickRangeByPrice(
            outcomeToken,
            _paymentToken,
            poolKey.tickSpacing,
            0,
            10000 // 10000 = 100% in basis points
        );

        validator.setBoundaries(poolKey.toId(), range.minTick, range.maxTick);
    }

    /// @notice Authorizes contract upgrades
    /// @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
