// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// external
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "./TruthMarket.sol";
import "./TruthMarketV2.sol";
import "./MarketEnums.sol";
import "./interfaces/IOracleBonds.sol";
import "./interfaces/IOracleCouncil.sol";
import "./interfaces/ITruthMarket.sol";
import "./libraries/Roles.sol";

// internal
import "./utils/libraries/AddressSetLib.sol";

contract TruthMarketManager is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressSetLib for AddressSetLib.AddressSet;

    // Structs ////////////////////////////////////////////////////

    struct MarketCreationParams {
        string marketQuestion;
        string marketSource;
        string additionalInfo;
        uint256 endOfTrading;
        uint256 yesNoTokenCap;
        address rewardToken;
        uint256 rewardAmount;
        string yesTokenSymbol;
        string noTokenSymbol;
        address paymentTokenAddress;
        uint24 fee; // V4 specific, V3 set to 0
        int24 tickSpacing; // V4 specific, V3 set to 0
        address hookAddress; // V4 specific, V3 set to address(0)
    }

    // State ////////////////////////////////////////////////////////

    AddressSetLib.AddressSet private _activeMarkets;

    uint256 public resolverBondAmount;
    uint256 public disputerBondAmount;
    uint256 public escalatorBondAmount;

    uint256 public firstChallengePeriod;
    uint256 public secondChallengePeriod;
    uint256 public minimumTradingDuration;

    uint256 public safeBoxPercentage;
    uint256 public creatorPercentage;
    uint256 public resolverPercentage;
    uint256 public maxOracleCouncilMembers;

    uint256 public yesNoTokenCap;
    uint256 public oracleBondsCheckIndex; // Tracks the progress of market bond chcek for Oracle Bonds updates

    address public truthMarketMastercopy;
    address public oracleCouncilAddress;
    address public safeBoxAddress;
    address public oracleBonds;
    address public paymentToken;
    address public uniswapV3Factory;
    address public rewardWallet;
    address public escalationAddress;

    mapping(address => address) public creatorAddress;
    mapping(address => address) public resolverAddress;

    // V4-related storage variables
    address public uniswapV4HookAddress; // V4 Hook contract address
    address public truthMarketV2Mastercopy; // TruthMarketV2 implementation contract

    // Events ////////////////////////////////////////////////////////

    event AddressesUpdated(
        address paymentToken,
        address truthMarketMastercopy,
        address oracleCouncilAddress,
        address safeBoxAddress,
        address uniswapV3Factory,
        address rewardWallet,
        address escalationAddress,
        address truthMarketV2Mastercopy,
        address uniswapV4HookAddress
    );

    event PercentagesUpdated(uint256 safeBoxPercentage, uint256 creatorPercentage, uint256 resolverPercentage);

    event DurationsUpdated(uint256 firstChallengePeriod, uint256 secondChallengePeriod, uint256 minimumTradingDuration);
    event LimitsUpdated(uint256 maxOracleCouncilMembers);

    event AmountsUpdated(
        uint256 resolverBondAmount, uint256 disputerBondAmount, uint256 escalatorBondAmount, uint256 yesNoTokenCap
    );

    event FlagsUpdated(bool _creationRestrictedToOwner, bool _openBidAllowed);

    event ResolutionProposed(address marketAddress, uint256 outcomePosition);
    event MarketCanceled(address marketAddress);
    event MarketReset(address marketAddress);
    event NewOracleBonds(address oracleBondsAddress);

    event MarketCreatedWithDescription(
        address marketAddress,
        string marketQuestion,
        string marketSource,
        string additionalInfo,
        uint256 endOfTrading,
        uint256 yesNoTokenCap,
        address marketOwner
    );

    // Errors ////////////////////////////////////////////////////////

    error NotOracleCouncil();
    error NotOracleCouncilAndOwner();
    error NotEscalationAndOwner();
    error InvalidEndOfTrading();
    error InvalidQuestion();
    error InvalidSource();
    error InvalidRewardWallet();
    error InvalidActionWhilePaused();
    error InvalidMarket(address market);
    error InvalidMarketStatus(MarketStatus status);
    error InvalidAddress();
    error NotCalledByMarket();
    error InvalidSymbolFormat(string symbol);
    error DuplicateSymbols(string symbol);
    error BondsNotSettled(address market);
    error InvalidFee(uint24 fee);
    error InvalidV2Mastercopy();
    error InvalidCreator();
    error InvalidPaymentToken();
    error AdminRoleLockedToOwner();
    error OwnershipRenounceDisabled();

    // Modifiers ////////////////////////////////////////////////////////

    modifier onlyOracleCouncil() {
        if (msg.sender != oracleCouncilAddress) {
            revert NotOracleCouncil();
        }
        _;
    }

    modifier onlyOracleCouncilAndOwner() {
        if (msg.sender != oracleCouncilAddress && msg.sender != owner()) {
            revert NotOracleCouncilAndOwner();
        }
        _;
    }

    modifier onlyEscalationAndOwner() {
        if (msg.sender != escalationAddress && msg.sender != owner()) {
            revert NotEscalationAndOwner();
        }
        _;
    }

    // Constructor ////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with default settings and roles
    /// @dev Sets up the owner, UUPS, Pausable, ReentrancyGuard, and default admin/pauser roles
    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _setupRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(Roles.PAUSER_ROLE, msg.sender);
    }

    // External functions //////////////////////////////////////////////

    /// @notice Creates a new market with specified parameters
    /// @param _marketQuestion The question that the market will resolve
    /// @param _marketSource The source that will be used to verify the outcome
    /// @param _additionalInfo Additional information about the market
    /// @param _endOfTrading The timestamp when trading will end
    /// @param _yesNoTokenCap The maximum amount of YES/NO tokens that can be minted
    /// @param _rewardToken The token used for rewards
    /// @param _rewardAmount The amount of reward tokens
    /// @param _yesTokenSymbol The symbol for the YES token (optional)
    /// @param _noTokenSymbol The symbol for the NO token (optional)
    function createMarket(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol
    ) external {
        // Call the new createMarketWithPaymentToken function with the system's default paymentToken
        createMarketWithPaymentToken(
            _marketQuestion,
            _marketSource,
            _additionalInfo,
            _endOfTrading,
            _yesNoTokenCap,
            _rewardToken,
            _rewardAmount,
            _yesTokenSymbol,
            _noTokenSymbol,
            paymentToken
        );
    }

    /// @notice Creates a new market with a specified payment token
    /// @param _marketQuestion The question that the market will resolve
    /// @param _marketSource The source that will be used to verify the outcome
    /// @param _additionalInfo Additional information about the market
    /// @param _endOfTrading The timestamp when trading will end
    /// @param _yesNoTokenCap The maximum amount of YES/NO tokens that can be minted
    /// @param _rewardToken The token used for rewards
    /// @param _rewardAmount The amount of reward tokens
    /// @param _yesTokenSymbol The symbol for the YES token (optional)
    /// @param _noTokenSymbol The symbol for the NO token (optional)
    /// @param _paymentToken The token to be used for payment in this market
    function createMarketWithPaymentToken(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol,
        address _paymentToken
    ) public nonReentrant whenNotPaused onlyRole(Roles.MARKET_CREATOR_ROLE) {
        MarketCreationParams memory params = MarketCreationParams({
            marketQuestion: _marketQuestion,
            marketSource: _marketSource,
            additionalInfo: _additionalInfo,
            endOfTrading: _endOfTrading,
            yesNoTokenCap: _yesNoTokenCap,
            rewardToken: _rewardToken,
            rewardAmount: _rewardAmount,
            yesTokenSymbol: _yesTokenSymbol,
            noTokenSymbol: _noTokenSymbol,
            paymentTokenAddress: _paymentToken,
            fee: 0, // V3 doesn't use fee
            tickSpacing: 0, // V3 doesn't use tickSpacing
            hookAddress: address(0) // V3 doesn't use hook address
        });

        _createMarketCommon(params, 1, msg.sender);
    }

    /// @notice Creates a new V4 market with dynamic fee and tick spacing
    /// @param _marketQuestion The question that the market will resolve
    /// @param _marketSource The source that will be used to verify the outcome
    /// @param _additionalInfo Additional information about the market
    /// @param _endOfTrading The timestamp when trading will end
    /// @param _yesNoTokenCap The maximum amount of YES/NO tokens that can be minted
    /// @param _rewardToken The token used for rewards
    /// @param _rewardAmount The amount of reward tokens
    /// @param _yesTokenSymbol The symbol for the YES token (optional)
    /// @param _noTokenSymbol The symbol for the NO token (optional)
    /// @param _fee The fee rate for V4 pools
    /// @param _tickSpacing The tick spacing for V4 pools
    function createMarketV2(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol,
        uint24 _fee,
        int24 _tickSpacing
    ) external nonReentrant whenNotPaused onlyRole(Roles.MARKET_CREATOR_ROLE) returns (address) {
        return _createMarketV2Internal(
                _marketQuestion,
                _marketSource,
                _additionalInfo,
                _endOfTrading,
                _yesNoTokenCap,
                _rewardToken,
                _rewardAmount,
                _yesTokenSymbol,
                _noTokenSymbol,
                _fee,
                _tickSpacing,
                msg.sender,
                paymentToken
            );
    }

    /// @notice Creates a new V4 market with an explicit creator address
    /// @dev Used by launcher contracts where msg.sender is not the actual market creator
    /// @param _creator The canonical creator address to record for this market
    function createMarketV2(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol,
        uint24 _fee,
        int24 _tickSpacing,
        address _creator
    ) external nonReentrant whenNotPaused onlyRole(Roles.MARKET_CREATOR_ROLE) returns (address) {
        return _createMarketV2Internal(
                _marketQuestion,
                _marketSource,
                _additionalInfo,
                _endOfTrading,
                _yesNoTokenCap,
                _rewardToken,
                _rewardAmount,
                _yesTokenSymbol,
                _noTokenSymbol,
                _fee,
                _tickSpacing,
                _creator,
                paymentToken
            );
    }

    /// @notice Creates a new V4 market with an explicit creator and payment token
    /// @dev Used by launcher contracts that need to pin the market's payment token to a
    ///      value they already hold (e.g. a Launchpad's own `paymentToken`), so that the
    ///      created market cannot drift if `setAddresses()` later rotates the manager's
    ///      global `paymentToken`. The supplied token is used as-is — callers are
    ///      responsible for passing a value that matches their own escrowed funds.
    /// @param _creator The canonical creator address to record for this market
    /// @param _paymentToken The payment token to pin on the created market (must be non-zero)
    function createMarketV2(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol,
        uint24 _fee,
        int24 _tickSpacing,
        address _creator,
        address _paymentToken
    ) external nonReentrant whenNotPaused onlyRole(Roles.MARKET_CREATOR_ROLE) returns (address) {
        return _createMarketV2Internal(
            _marketQuestion,
            _marketSource,
            _additionalInfo,
            _endOfTrading,
            _yesNoTokenCap,
            _rewardToken,
            _rewardAmount,
            _yesTokenSymbol,
            _noTokenSymbol,
            _fee,
            _tickSpacing,
            _creator,
            _paymentToken
        );
    }

    /// @dev Shared implementation for the explicit-creator `createMarketV2` overloads.
    ///      Runs cheap calldata checks before any SLOAD so reverts on bad input stay cheap.
    function _createMarketV2Internal(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol,
        uint24 _fee,
        int24 _tickSpacing,
        address _creator,
        address _paymentToken
    ) private returns (address) {
        if (_fee > 10000) {
            revert InvalidFee(_fee);
        }
        if (_creator == address(0)) {
            revert InvalidCreator();
        }
        if (_paymentToken == address(0)) {
            revert InvalidPaymentToken();
        }
        if (truthMarketV2Mastercopy == address(0)) {
            revert InvalidV2Mastercopy();
        }

        MarketCreationParams memory params = MarketCreationParams({
            marketQuestion: _marketQuestion,
            marketSource: _marketSource,
            additionalInfo: _additionalInfo,
            endOfTrading: _endOfTrading,
            yesNoTokenCap: _yesNoTokenCap,
            rewardToken: _rewardToken,
            rewardAmount: _rewardAmount,
            yesTokenSymbol: _yesTokenSymbol,
            noTokenSymbol: _noTokenSymbol,
            paymentTokenAddress: _paymentToken,
            fee: _fee,
            tickSpacing: _tickSpacing,
            hookAddress: uniswapV4HookAddress
        });

        return _createMarketCommon(params, 2, _creator);
    }

    /// @notice Resolves a market by Oracle Council decision
    /// @param _marketAddress The address of the market to resolve
    /// @param _outcomePosition The outcome position (YES/NO) to resolve the market with
    function resolveMarketByCouncil(address _marketAddress, uint256 _outcomePosition)
        external
        whenNotPaused
        onlyOracleCouncil
    {
        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resolveMarketByCouncil(_outcomePosition);
    }

    /// @notice Resolves a market through escalation process
    /// @param _marketAddress The address of the market to resolve
    /// @param _outcomePosition The outcome position (YES/NO) to resolve the market with
    function resolveMarketByEscalation(address _marketAddress, uint256 _outcomePosition)
        external
        whenNotPaused
        onlyEscalationAndOwner
    {
        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resolveMarketByEscalation(_outcomePosition);
    }

    /// @notice Proposes a resolution for a market
    /// @param _marketAddress The address of the market to propose resolution for
    /// @param _outcomePosition The outcome position (YES/NO) being proposed
    function proposeResolution(address _marketAddress, uint256 _outcomePosition) external whenNotPaused {
        if (!isActiveMarket(_marketAddress)) {
            revert InvalidMarket(_marketAddress);
        }

        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }

        ITruthMarket(_marketAddress).proposeResolution(_outcomePosition);
        IOracleBonds(oracleBonds)
            .sendResolverBondToMarket(_marketAddress, msg.sender, ITruthMarket(_marketAddress).resolverBondAmount());

        resolverAddress[_marketAddress] = msg.sender;
        emit ResolutionProposed(_marketAddress, _outcomePosition);
    }

    /// @notice Resets a market's state by Oracle Council decision
    /// @param _marketAddress The address of the market to reset
    /// @param _returnToOpenForResolution Whether to return the market to open for resolution state
    function resetMarketByCouncil(address _marketAddress, bool _returnToOpenForResolution)
        external
        whenNotPaused
        onlyOracleCouncil
    {
        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resetMarketByCouncil(_returnToOpenForResolution);
    }

    /// @notice Resets a market's state through escalation process
    /// @param _marketAddress The address of the market to reset
    function resetMarketByEscalation(address _marketAddress) external whenNotPaused onlyEscalationAndOwner {
        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resetMarketByEscalation();
    }

    /// @notice Disputes a market's proposed resolution
    /// @param _marketAddress The address of the market to dispute
    /// @param _disputor The address of the account disputing the resolution
    function disputeMarket(address _marketAddress, address _disputor) external onlyOracleCouncilAndOwner whenNotPaused {
        if (!isActiveMarket(_marketAddress)) {
            revert InvalidMarket(_marketAddress);
        }
        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }
        MarketStatus currentStatus = ITruthMarket(_marketAddress).getCurrentStatus();
        if (currentStatus != MarketStatus.ResolutionProposed && currentStatus != MarketStatus.DisputeRaised) {
            revert InvalidMarketStatus(currentStatus);
        }
        IOracleBonds(oracleBonds)
            .sendDisputorBondToMarket(_marketAddress, _disputor, ITruthMarket(_marketAddress).disputerBondAmount());
        if (currentStatus == MarketStatus.ResolutionProposed) {
            ITruthMarket(_marketAddress).raiseDispute();
        }
    }

    /// @notice Escalates a market dispute to a higher level
    /// @param _marketAddress The address of the market to escalate
    /// @param _disputor The address of the account escalating the dispute
    function escalateDisputeMarket(address _marketAddress, address _disputor)
        external
        onlyEscalationAndOwner
        whenNotPaused
    {
        if (!isActiveMarket(_marketAddress)) {
            revert InvalidMarket(_marketAddress);
        }
        if (ITruthMarket(_marketAddress).paused()) {
            revert InvalidActionWhilePaused();
        }
        IOracleBonds(oracleBonds)
            .sendEscalatedDisputorBondToMarket(
                _marketAddress, _disputor, ITruthMarket(_marketAddress).escalatorBondAmount()
            );
        ITruthMarket(_marketAddress).raiseEscalatedDispute();
    }

    /// @notice Resets a market's status and reopens it for disputes
    /// @param _market The address of the market to reset
    function resetMarketStatus(address _market) external {
        if (!isActiveMarket(msg.sender)) {
            revert InvalidMarket(msg.sender);
        }
        if (_market != msg.sender) {
            revert NotCalledByMarket();
        }

        IOracleCouncil(oracleCouncilAddress).reopenMarketForDisputes(_market);
        IEscalation(escalationAddress).resetEscalationStatus(_market);
    }

    /// @notice Sets the maximum amount of YES/NO tokens that can be minted for a market
    /// @param _market The address of the market to update
    /// @param _yesNoTokenCap The new maximum token cap
    function setYesNoTokenCap(address _market, uint256 _yesNoTokenCap) external onlyOracleCouncilAndOwner {
        ITruthMarket(_market).setYesNoTokenCap(_yesNoTokenCap);
    }

    /// @notice Sets the end of trading time for a market
    /// @param _market The address of the market to update
    /// @param _endOfTrading The new end of trading timestamp
    function setEndOfTrading(address _market, uint256 _endOfTrading) external onlyOwner {
        ITruthMarket(_market).setEndOfTrading(_endOfTrading);
    }

    /// @notice Sets the duration of the first challenge period for a market
    /// @param _market The address of the market to update
    /// @param _firstChallengePeriod The new duration in seconds
    function setFirstChallengePeriod(address _market, uint256 _firstChallengePeriod) external onlyOwner {
        ITruthMarket(_market).setFirstChallengePeriod(_firstChallengePeriod);
    }

    /// @notice Sets the duration of the second challenge period for a market
    /// @param _market The address of the market to update
    /// @param _secondChallengePeriod The new duration in seconds
    function setSecondChallengePeriod(address _market, uint256 _secondChallengePeriod) external onlyOwner {
        ITruthMarket(_market).setSecondChallengePeriod(_secondChallengePeriod);
    }

    /// @notice Updates various contract addresses used by the market manager
    /// @dev WARNING: `oracleCouncilAddress` and `escalationAddress` are cached by each
    ///      TruthMarket / TruthMarketV2 instance at initialization time and are not
    ///      refreshed afterwards. Rotating either of these proxy addresses while any
    ///      market is still live in the dispute / escalation / reset / bond-settlement
    ///      lifecycle can leave that market un-settleable, because the manager will
    ///      authorize the new contracts while existing markets still read dispute state
    ///      from the old ones. In normal operation these contracts are upgraded in
    ///      place via UUPS, which preserves both the proxy address and historical
    ///      dispute state. Before rotating these two proxies, verify that no market is
    ///      currently in the dispute / escalation / reset / bond-settlement lifecycle.
    /// @param _truthMarketMastercopy The address of the truth market implementation contract
    /// @param _oracleCouncilAddress The address of the Oracle Council contract
    /// @param _paymentToken The address of the payment token contract
    /// @param _safeBoxAddress The address where fees are collected
    /// @param _uniswapV3Factory The address of the Uniswap V3 factory
    /// @param _rewardWallet The address of the reward wallet
    /// @param _escalationAddress The address of the escalation contract
    function setAddresses(
        address _truthMarketMastercopy,
        address _oracleCouncilAddress,
        address _paymentToken,
        address _safeBoxAddress,
        address _uniswapV3Factory,
        address _rewardWallet,
        address _escalationAddress,
        address _truthMarketV2Mastercopy,
        address _uniswapV4HookAddress
    ) external onlyOwner {
        if (_paymentToken != paymentToken) {
            paymentToken = _paymentToken;
        }
        if (_truthMarketMastercopy != truthMarketMastercopy) {
            truthMarketMastercopy = _truthMarketMastercopy;
        }
        if (_oracleCouncilAddress != oracleCouncilAddress) {
            oracleCouncilAddress = _oracleCouncilAddress;
        }

        if (_safeBoxAddress != safeBoxAddress) {
            safeBoxAddress = _safeBoxAddress;
        }
        if (_uniswapV3Factory != uniswapV3Factory) {
            uniswapV3Factory = _uniswapV3Factory;
        }
        if (_rewardWallet != rewardWallet) {
            rewardWallet = _rewardWallet;
        }

        if (_escalationAddress != escalationAddress) {
            escalationAddress = _escalationAddress;
        }

        // V4-related address updates
        if (_truthMarketV2Mastercopy != address(0) && _truthMarketV2Mastercopy != truthMarketV2Mastercopy) {
            truthMarketV2Mastercopy = _truthMarketV2Mastercopy;
        }

        if (_uniswapV4HookAddress != address(0) && _uniswapV4HookAddress != uniswapV4HookAddress) {
            uniswapV4HookAddress = _uniswapV4HookAddress;
        }

        emit AddressesUpdated(
            _paymentToken,
            _truthMarketMastercopy,
            _oracleCouncilAddress,
            _safeBoxAddress,
            _uniswapV3Factory,
            _rewardWallet,
            _escalationAddress,
            _truthMarketV2Mastercopy,
            _uniswapV4HookAddress
        );
    }

    /// @notice Updates the percentage splits for fees
    /// @param _safeBoxPercentage Percentage of fees going to safe box
    /// @param _creatorPercentage Percentage of fees going to market creator
    /// @param _resolverPercentage Percentage of fees going to resolver
    function setPercentages(uint256 _safeBoxPercentage, uint256 _creatorPercentage, uint256 _resolverPercentage)
        external
        onlyOwner
    {
        if (_safeBoxPercentage != safeBoxPercentage) {
            safeBoxPercentage = _safeBoxPercentage;
        }
        if (_creatorPercentage != creatorPercentage) {
            creatorPercentage = _creatorPercentage;
        }
        if (_resolverPercentage != resolverPercentage) {
            resolverPercentage = _resolverPercentage;
        }
        emit PercentagesUpdated(_safeBoxPercentage, _creatorPercentage, _resolverPercentage);
    }

    /// @notice Sets various duration parameters for markets
    /// @param _firstChallengePeriod Duration of first challenge period in seconds
    /// @param _secondChallengePeriod Duration of second challenge period in seconds
    /// @param _minimumTradingDuration Minimum duration a market must be open for trading
    function setDurations(
        uint256 _firstChallengePeriod,
        uint256 _secondChallengePeriod,
        uint256 _minimumTradingDuration
    ) external onlyOwner {
        if (_firstChallengePeriod != firstChallengePeriod) {
            firstChallengePeriod = _firstChallengePeriod;
        }

        if (_secondChallengePeriod != secondChallengePeriod) {
            secondChallengePeriod = _secondChallengePeriod;
        }

        if (_minimumTradingDuration != minimumTradingDuration) {
            minimumTradingDuration = _minimumTradingDuration;
        }

        emit DurationsUpdated(_firstChallengePeriod, _secondChallengePeriod, _minimumTradingDuration);
    }

    /// @notice Sets the maximum number of Oracle Council members
    /// @param _maxOracleCouncilMembers The new maximum number of council members
    function setLimits(uint256 _maxOracleCouncilMembers) external onlyOwner {
        if (_maxOracleCouncilMembers != maxOracleCouncilMembers) {
            maxOracleCouncilMembers = _maxOracleCouncilMembers;
        }

        emit LimitsUpdated(_maxOracleCouncilMembers);
    }

    /// @notice Sets various amount parameters for bonds and token caps
    /// @param _resolverBondAmount Amount required for resolver bond
    /// @param _disputerBondAmount Amount required for disputer bond
    /// @param _escalatorBondAmount Amount required for escalator bond
    /// @param _yesNoTokenCap Maximum amount of YES/NO tokens that can be minted
    function setAmounts(
        uint256 _resolverBondAmount,
        uint256 _disputerBondAmount,
        uint256 _escalatorBondAmount,
        uint256 _yesNoTokenCap
    ) external onlyOwner {
        if (_resolverBondAmount != resolverBondAmount) {
            resolverBondAmount = _resolverBondAmount;
        }

        if (_disputerBondAmount != disputerBondAmount) {
            disputerBondAmount = _disputerBondAmount;
        }

        if (_escalatorBondAmount != escalatorBondAmount) {
            escalatorBondAmount = _escalatorBondAmount;
        }

        if (_yesNoTokenCap != yesNoTokenCap) {
            yesNoTokenCap = _yesNoTokenCap;
        }

        emit AmountsUpdated(_resolverBondAmount, _disputerBondAmount, _escalatorBondAmount, _yesNoTokenCap);
    }

    /// @notice Updates the Oracle Bonds contract address
    /// @param _oracleBonds The new Oracle Bonds contract address
    /// @dev WARNING: OracleBonds is a UUPS upgradeable proxy — normal upgrades do NOT require changing
    /// this address. Only call this function to point to an entirely new proxy deployment.
    /// The `bondSettled` gate does NOT cover disputor bonds still claimable via
    /// `OracleCouncil.claimUnclosedDisputeBonds()`. Switching the address while unclosed dispute bonds
    /// remain in the old contract will break the permissionless claim path for those disputors.
    /// Before calling, verify that no disputor bonds remain claimable in the old OracleBonds contract.
    function setOracleBonds(address _oracleBonds) external onlyOwner {
        if (_oracleBonds == address(0)) {
            revert InvalidAddress();
        }

        // Check all active markets have settled their bonds
        uint256 marketCount = _activeMarkets.elements.length;
        for (uint256 i = 0; i < marketCount; i++) {
            address market = _activeMarkets.elements[i];
            if (!ITruthMarket(market).bondSettled()) {
                revert BondsNotSettled(market);
            }
        }

        // remove old oracleBonds approval
        if (oracleBonds != address(0)) {
            IERC20(paymentToken).approve(address(oracleBonds), 0);
        }

        oracleBonds = _oracleBonds;
        // approve new oracleBonds
        IERC20(paymentToken).approve(address(oracleBonds), type(uint256).max);

        emit NewOracleBonds(_oracleBonds);
    }

    /**
     * @notice Updates the Oracle Bonds address in batches to avoid gas limit issues
     * @dev Processes a specified number of markets per transaction to check if bonds are settled
     * @dev Updates the Oracle Bonds address only after all markets have been verified
     * @dev WARNING: OracleBonds is a UUPS upgradeable proxy — normal upgrades do NOT require changing
     * this address. Only call this function to point to an entirely new proxy deployment.
     * The `bondSettled` gate does NOT cover disputor bonds still claimable via
     * `OracleCouncil.claimUnclosedDisputeBonds()`. Switching the address while unclosed dispute bonds
     * remain in the old contract will break the permissionless claim path for those disputors.
     * Before calling, verify that no disputor bonds remain claimable in the old OracleBonds contract.
     * @param _oracleBonds New Oracle Bonds address
     * @param batchSize Number of markets to check in this transaction
     * @return completed Whether all markets have been processed
     * @return processedCount Number of markets processed in this transaction
     * @return totalCount Total number of markets to process
     */
    function setOracleBondsWithBatchCheck(address _oracleBonds, uint256 batchSize)
        external
        onlyOwner
        returns (bool completed, uint256 processedCount, uint256 totalCount)
    {
        if (_oracleBonds == address(0)) {
            revert InvalidAddress();
        }

        uint256 marketCount = _activeMarkets.elements.length;
        uint256 endIndex = MathUpgradeable.min(oracleBondsCheckIndex + batchSize, marketCount);

        // Process the current batch
        for (uint256 i = oracleBondsCheckIndex; i < endIndex; i++) {
            address market = _activeMarkets.elements[i];
            if (!ITruthMarket(market).bondSettled()) {
                revert BondsNotSettled(market);
            }
        }

        // Update the processed index
        uint256 previousIndex = oracleBondsCheckIndex;
        oracleBondsCheckIndex = endIndex;

        // If all markets have been processed, update the Oracle Bonds address
        if (oracleBondsCheckIndex == marketCount) {
            // Reset the index for future operations
            oracleBondsCheckIndex = 0;

            // Remove old Oracle Bonds approval
            if (oracleBonds != address(0)) {
                IERC20(paymentToken).approve(address(oracleBonds), 0);
            }

            oracleBonds = _oracleBonds;
            // Approve new Oracle Bonds
            IERC20(paymentToken).approve(address(oracleBonds), type(uint256).max);

            emit NewOracleBonds(_oracleBonds);

            completed = true;
        } else {
            completed = false;
        }

        return (completed, endIndex - previousIndex, marketCount);
    }

    /// @notice Pauses all market operations
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all market operations
    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // External view functions ////////////////////////////////////////

    /// @notice Checks if a given address is an active market
    /// @param _marketAddress The address to check
    /// @return bool True if the address is an active market
    function isActiveMarket(address _marketAddress) public view returns (bool) {
        return _activeMarkets.contains(_marketAddress);
    }

    /// @notice Gets the total number of active markets
    /// @return uint256 The number of active markets
    function numberOfActiveMarkets() external view returns (uint256) {
        return _activeMarkets.elements.length;
    }

    /// @notice Gets the address of an active market by index
    /// @param _index The index of the market to retrieve
    /// @return address The market address at the given index
    function getActiveMarketAddress(uint256 _index) external view returns (address) {
        return _activeMarkets.elements[_index];
    }

    // Internal functions //////////////////////////////////////////////

    /// @notice Internal function to create markets with shared logic
    /// @param params Market creation parameters
    /// @param version Market version (1 for V3, 2 for V4)
    function _createMarketCommon(MarketCreationParams memory params, uint8 version, address creator)
        internal
        returns (address)
    {
        // Common validations
        if (params.endOfTrading < block.timestamp + minimumTradingDuration) {
            revert InvalidEndOfTrading();
        }
        if (bytes(params.marketQuestion).length == 0) {
            revert InvalidQuestion();
        }
        if (bytes(params.marketSource).length == 0) {
            revert InvalidSource();
        }
        if (params.paymentTokenAddress == address(0)) {
            revert InvalidAddress();
        }

        // Set and validate symbols
        string memory _finalYesSymbol = bytes(params.yesTokenSymbol).length > 0 ? params.yesTokenSymbol : "YES";
        string memory _finalNoSymbol = bytes(params.noTokenSymbol).length > 0 ? params.noTokenSymbol : "NO";

        if (!_isValidSymbol(_finalYesSymbol)) revert InvalidSymbolFormat(_finalYesSymbol);
        if (!_isValidSymbol(_finalNoSymbol)) revert InvalidSymbolFormat(_finalNoSymbol);

        // Check for duplicate symbols
        if (keccak256(bytes(_finalYesSymbol)) == keccak256(bytes(_finalNoSymbol))) {
            revert DuplicateSymbols(_finalYesSymbol);
        }

        // Create tokens
        YesNoToken yesToken = new YesNoToken(string.concat(_finalYesSymbol, " Token"), _finalYesSymbol);
        YesNoToken noToken = new YesNoToken(string.concat(_finalNoSymbol, " Token"), _finalNoSymbol);

        address marketAddress;

        if (version == 1) {
            // V3 market creation
            TruthMarket truthMarket = TruthMarket(Clones.clone(truthMarketMastercopy));
            truthMarket.initialize(
                params.marketQuestion,
                params.marketSource,
                params.additionalInfo,
                params.endOfTrading,
                params.yesNoTokenCap,
                params.paymentTokenAddress,
                address(yesToken),
                address(noToken),
                params.rewardToken,
                params.rewardAmount
            );
            marketAddress = address(truthMarket);
        } else {
            // V4 market creation
            TruthMarketV2 truthMarketV2 = TruthMarketV2(Clones.clone(truthMarketV2Mastercopy));
            truthMarketV2.initialize(
                params.marketQuestion,
                params.marketSource,
                params.additionalInfo,
                params.endOfTrading,
                params.yesNoTokenCap,
                params.paymentTokenAddress,
                address(yesToken),
                address(noToken),
                params.rewardToken,
                params.rewardAmount,
                params.fee,
                params.tickSpacing,
                params.hookAddress
            );
            marketAddress = address(truthMarketV2);
        }

        // Transfer rewards if any
        if (params.rewardAmount > 0) {
            if (hasRole(Roles.REWARD_SPENDER_ROLE, msg.sender)) {
                if (rewardWallet == address(0)) revert InvalidRewardWallet();
                IERC20Upgradeable(params.rewardToken).safeTransferFrom(rewardWallet, marketAddress, params.rewardAmount);
            } else {
                IERC20Upgradeable(params.rewardToken).safeTransferFrom(msg.sender, marketAddress, params.rewardAmount);
            }
        }

        // Transfer token ownership
        yesToken.transferOwnership(marketAddress);
        noToken.transferOwnership(marketAddress);

        // Register market
        creatorAddress[marketAddress] = creator;
        _activeMarkets.add(marketAddress);

        emit MarketCreatedWithDescription(
            marketAddress,
            params.marketQuestion,
            params.marketSource,
            params.additionalInfo,
            params.endOfTrading,
            params.yesNoTokenCap,
            creator
        );

        return marketAddress;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _isValidSymbol(string memory symbol) internal pure returns (bool) {
        bytes memory b = bytes(symbol);
        if (b.length == 0 || b.length > 20) return false;

        for (uint256 i; i < b.length; i++) {
            bytes1 char = b[i];
            if (
                !(char >= 0x30 && char <= 0x39) // 0-9
                    && !(char >= 0x41 && char <= 0x5A) // A-Z
                    && !(char >= 0x61 && char <= 0x7A) // a-z
                    && !(char == 0x20) // space
                    && !(char == 0x2D) // hyphen
            ) return false;
        }
        return true;
    }

    // Ownership / admin binding //////////////////////////////////////////
    //
    // The contract inherits both Ownable and AccessControl, which were wired up
    // independently in `initialize`. To prevent governance handoff drift (owner
    // moves but DEFAULT_ADMIN_ROLE stays behind, or DEFAULT_ADMIN_ROLE gets
    // granted to a third party via AccessControl's native grantRole), the
    // following overrides bind the two systems:
    //
    // - transferOwnership atomically migrates DEFAULT_ADMIN_ROLE along with
    //   the Ownable slot, so future handoffs cannot leave a stale admin behind.
    // - renounceOwnership is disabled, since a zero owner would brick UUPS
    //   upgrades (_authorizeUpgrade is onlyOwner) and orphan the admin role.
    // - grantRole / revokeRole / renounceRole reject direct changes to
    //   DEFAULT_ADMIN_ROLE, forcing all admin rotation to go through
    //   transferOwnership. Other roles (PAUSER_ROLE, MARKET_CREATOR_ROLE, etc.)
    //   are unaffected and continue to use standard AccessControl flows.

    /// @notice Transfer ownership and atomically migrate DEFAULT_ADMIN_ROLE.
    /// @dev Overridden to keep `owner()` and `DEFAULT_ADMIN_ROLE` in sync.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();

        address oldOwner = owner();
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, newOwner);
        // Skip the revoke in the self-transfer case; otherwise we'd wipe the
        // admin role we just granted back to the same account.
        if (oldOwner != newOwner) {
            _revokeRole(Roles.DEFAULT_ADMIN_ROLE, oldOwner);
        }
        _transferOwnership(newOwner);
    }

    /// @notice Renouncing ownership would brick UUPS upgrades and orphan admin.
    function renounceOwnership() public pure override {
        revert OwnershipRenounceDisabled();
    }

    /// @notice Block direct grants of DEFAULT_ADMIN_ROLE; rotate via transferOwnership.
    function grantRole(bytes32 role, address account) public override {
        if (role == Roles.DEFAULT_ADMIN_ROLE) revert AdminRoleLockedToOwner();
        super.grantRole(role, account);
    }

    /// @notice Block removing DEFAULT_ADMIN_ROLE from the current owner.
    ///         Stale historical admins (non-owner) can still be revoked.
    function revokeRole(bytes32 role, address account) public override {
        if (role == Roles.DEFAULT_ADMIN_ROLE && account == owner()) {
            revert AdminRoleLockedToOwner();
        }
        super.revokeRole(role, account);
    }

    /// @notice Block self-renunciation of DEFAULT_ADMIN_ROLE by the current owner.
    function renounceRole(bytes32 role, address account) public override {
        if (role == Roles.DEFAULT_ADMIN_ROLE && account == owner()) {
            revert AdminRoleLockedToOwner();
        }
        super.renounceRole(role, account);
    }
}
