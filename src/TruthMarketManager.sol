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
import "@openzeppelin/contracts/proxy/Clones.sol";

import "./TruthMarket.sol";
import "./MarketEnums.sol";
import "./interfaces/IOracleBonds.sol";
import "./interfaces/IOracleCouncil.sol";
import "./interfaces/ITruthMarket.sol";

// internal
import "./utils/libraries/AddressSetLib.sol";

contract TruthMarketManager is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressSetLib for AddressSetLib.AddressSet;

    // State ////////////////////////////////////////////////////////
 
    AddressSetLib.AddressSet private _activeMarkets;

    uint256 public resolverBondAmount;
    uint256 public disputerBondAmount;
    uint256 public escalatorBondAmount;

    uint256 public firstChallengePeriod;
    uint256 public secondChallengePeriod;
    uint256 public minimumTradingDuration;

    uint public safeBoxPercentage;
    uint public creatorPercentage;
    uint public resolverPercentage;
    uint public maxOracleCouncilMembers;
    uint public pausersCount;
    
    uint public yesNoTokenCap;

    address public truthMarketMastercopy;
    address public oracleCouncilAddress;
    address public safeBoxAddress;
    address public oracleBonds;
    address public paymentToken;
    address public uniswapV3Factory;
    address public rewardWallet;
    address public escalationAddress;
    
    mapping(uint => address) public pauserAddress;
    mapping(address => uint) public pauserIndex;

    mapping(address => address) public creatorAddress;
    mapping(address => address) public resolverAddress;
    
    // Events ////////////////////////////////////////////////////////

    event AddressesUpdated(
        address paymentToken,
        address truthMarketMastercopy,
        address oracleCouncilAddress,
        address safeBoxAddress,
        address uniswapV3Factory,
        address rewardWallet,
        address escalationAddress
    );

    event PercentagesUpdated(
        uint safeBoxPercentage,
        uint creatorPercentage,
        uint resolverPercentage
    );

    event DurationsUpdated(
        uint256 firstChallengePeriod,
        uint256 secondChallengePeriod,
        uint256 minimumTradingDuration
    );
    event LimitsUpdated(
        uint maxOracleCouncilMembers
    );

    event AmountsUpdated(
        uint resolverBondAmount,
        uint disputerBondAmount,
        uint escalatorBondAmount,
        uint yesNoTokenCap
    );

    event FlagsUpdated(bool _creationRestrictedToOwner, bool _openBidAllowed);

    event ResolutionProposed(address marketAddress, uint outcomePosition);
    event MarketCanceled(address marketAddress);
    event MarketReset(address marketAddress);
    event PauserAddressAdded(address pauserAddress);
    event PauserAddressRemoved(address pauserAddress);
    event NewOracleBonds(address oracleBondsAddress);

    event MarketCreatedWithDescription(
        address marketAddress,
        string marketQuestion,
        string marketSource,
        string additionalInfo,
        uint endOfTrading,
        uint yesNoTokenCap,
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
    error PauserExists(address pauserAddress);
    error PauserDoesNotExist(address pauserAddress);
    
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

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }
    
    // External functions //////////////////////////////////////////////

    function createMarket(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint _endOfTrading,
        uint _yesNoTokenCap,
        address _rewardToken,
        uint _rewardAmount
    ) external nonReentrant whenNotPaused onlyOracleCouncilAndOwner {
        if (_endOfTrading < block.timestamp + minimumTradingDuration) {
            revert InvalidEndOfTrading();
        }
        if (keccak256(abi.encode(_marketQuestion)) == keccak256(abi.encode(""))) {
            revert InvalidQuestion();
        }
        if (keccak256(abi.encode(_marketSource)) == keccak256(abi.encode(""))) {
            revert InvalidSource();
        }

        if (rewardWallet == address(0)) {
            revert InvalidRewardWallet();
        }
        
        TruthMarket truthMarket = TruthMarket(Clones.clone(truthMarketMastercopy));

        YesNoToken yesToken = new YesNoToken("YES Token", "YES");
        YesNoToken noToken = new YesNoToken("NO Token", "NO");

        truthMarket.initialize(
            _marketQuestion,
            _marketSource,
            _additionalInfo,
            _endOfTrading,
            _yesNoTokenCap,
            address(paymentToken),
            address(yesToken),
            address(noToken),
            _rewardToken
        );

        if (_rewardAmount > 0) {
            IERC20Upgradeable(_rewardToken).safeTransferFrom(rewardWallet, address(truthMarket), _rewardAmount);
        }

        yesToken.transferOwnership(address(truthMarket));
        noToken.transferOwnership(address(truthMarket));

        creatorAddress[address(truthMarket)] = msg.sender;
        _activeMarkets.add(address(truthMarket));

        emit MarketCreatedWithDescription(
            address(truthMarket),
            _marketQuestion,
            _marketSource,
            _additionalInfo,
            _endOfTrading,
            _yesNoTokenCap,
            msg.sender
        );
    }
    function resolveMarketByCouncil(address _marketAddress, uint _outcomePosition) external whenNotPaused onlyOracleCouncilAndOwner {
        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resolveMarketByCouncil(_outcomePosition);
    }
    function resolveMarketByEscalation(address _marketAddress, uint _outcomePosition) external whenNotPaused onlyEscalationAndOwner {
        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resolveMarketByEscalation(_outcomePosition);
    }

    function proposeResolution(address _marketAddress, uint _outcomePosition) external whenNotPaused {
        if (!isActiveMarket(_marketAddress)) {
            revert InvalidMarket(_marketAddress);
        }

        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        
        IOracleBonds(oracleBonds).sendResolverBondToMarket(
            _marketAddress,
            msg.sender,
            ITruthMarket(_marketAddress).resolverBondAmount()
        );
        
        resolverAddress[_marketAddress] = msg.sender;
        ITruthMarket(_marketAddress).proposeResolution(_outcomePosition);
        emit ResolutionProposed(_marketAddress, _outcomePosition);
    }

    function resetMarketByCouncil(address _marketAddress, bool _returnToOpenForResolution) external whenNotPaused onlyOracleCouncilAndOwner {
        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resetMarketByCouncil(_returnToOpenForResolution);
    }
    function resetMarketByEscalation(address _marketAddress) external whenNotPaused onlyEscalationAndOwner {
        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        ITruthMarket(_marketAddress).resetMarketByEscalation();
    }

    function disputeMarket(address _marketAddress, address _disputor) external onlyOracleCouncil whenNotPaused {
        if (!isActiveMarket(_marketAddress)) {
            revert InvalidMarket(_marketAddress);
        }
        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        IOracleBonds(oracleBonds).sendDisputorBondToMarket(
            _marketAddress,
            _disputor,
            ITruthMarket(_marketAddress).disputerBondAmount()
        );
        if (ITruthMarket(_marketAddress).getCurrentStatus() == MarketStatus.ResolutionProposed) {
            ITruthMarket(_marketAddress).raiseDispute();
        }
    }

    function escalateDisputeMarket(address _marketAddress, address _disputor) external onlyEscalationAndOwner whenNotPaused {
        if (!isActiveMarket(_marketAddress)) {
            revert InvalidMarket(_marketAddress);
        }
        if (ITruthMarket(_marketAddress).paused() && msg.sender != owner()) {
            revert InvalidActionWhilePaused();
        }
        IOracleBonds(oracleBonds).sendEscalatedDisputorBondToMarket(
            _marketAddress,
            _disputor,
            ITruthMarket(_marketAddress).escalatorBondAmount()
        );
        ITruthMarket(_marketAddress).raiseEscalatedDispute();
    }

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

    function setYesNoTokenCap(address _market, uint _yesNoTokenCap) external onlyOracleCouncilAndOwner {
        ITruthMarket(_market).setYesNoTokenCap(_yesNoTokenCap);
    }
    
    function setEndOfTrading(address _market, uint _endOfTrading) external onlyOracleCouncilAndOwner {
        ITruthMarket(_market).setEndOfTrading(_endOfTrading);
    }
    
    function setFirstChallengePeriod(address _market, uint256 _firstChallengePeriod) external onlyOracleCouncilAndOwner {
        ITruthMarket(_market).setFirstChallengePeriod(_firstChallengePeriod);
    }

    function setSecondChallengePeriod(address _market, uint256 _secondChallengePeriod) external onlyOracleCouncilAndOwner {
        ITruthMarket(_market).setSecondChallengePeriod(_secondChallengePeriod);
    }

    function setAddresses(
        address _truthMarketMastercopy,
        address _oracleCouncilAddress,
        address _paymentToken,
        address _safeBoxAddress,
        address _uniswapV3Factory,
        address _rewardWallet,
        address _escalationAddress
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

        emit AddressesUpdated(
            _truthMarketMastercopy,
            _oracleCouncilAddress,
            _paymentToken,
            _safeBoxAddress,
            _uniswapV3Factory,
            _rewardWallet,
            _escalationAddress
        );
    }

    function setPercentages(
        uint _safeBoxPercentage,
        uint _creatorPercentage,
        uint _resolverPercentage
    ) external onlyOwner {
        if (_safeBoxPercentage != safeBoxPercentage) {
            safeBoxPercentage = _safeBoxPercentage;
        }
        if (_creatorPercentage != creatorPercentage) {
            creatorPercentage = _creatorPercentage;
        }
        if (_resolverPercentage != resolverPercentage) {
            resolverPercentage = _resolverPercentage;
        }
        emit PercentagesUpdated(
            _safeBoxPercentage,
            _creatorPercentage,
            _resolverPercentage
        );
    }

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

        emit DurationsUpdated(
            _firstChallengePeriod,
            _secondChallengePeriod,
            _minimumTradingDuration
        );
    }

    function setLimits(
        uint _maxOracleCouncilMembers
    ) external onlyOwner {

        if (_maxOracleCouncilMembers != maxOracleCouncilMembers) {
            maxOracleCouncilMembers = _maxOracleCouncilMembers;
        }

        emit LimitsUpdated(
            _maxOracleCouncilMembers
        );
    }

    function setAmounts(
        uint _resolverBondAmount,
        uint _disputerBondAmount,
        uint _escalatorBondAmount,
        uint _yesNoTokenCap
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

        emit AmountsUpdated(
            _resolverBondAmount,
            _disputerBondAmount,
            _escalatorBondAmount,
            _yesNoTokenCap
        );
    }

    function setOracleBonds(address _oracleBonds) external onlyOwner {
        if (_oracleBonds == address(0)) {
            revert InvalidAddress();
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

    function addPauserAddress(address _pauserAddress) external onlyOracleCouncilAndOwner {
        if (_pauserAddress == address(0)) {
            revert InvalidAddress();
        }
        if (pauserIndex[_pauserAddress] != 0) {
            revert PauserExists(_pauserAddress);
        }
        pausersCount = pausersCount + 1;
        pauserIndex[_pauserAddress] = pausersCount;
        pauserAddress[pausersCount] = _pauserAddress;
        emit PauserAddressAdded(_pauserAddress);
    }

    function removePauserAddress(address _pauserAddress) external onlyOracleCouncilAndOwner {
        if (_pauserAddress == address(0)) {
            revert InvalidAddress();
        }
        if (pauserIndex[_pauserAddress] == 0) {
            revert PauserDoesNotExist(_pauserAddress);
        }
        pauserAddress[pauserIndex[_pauserAddress]] = pauserAddress[pausersCount];
        pauserIndex[pauserAddress[pausersCount]] = pauserIndex[_pauserAddress];
        pausersCount = pausersCount - 1;
        pauserIndex[_pauserAddress] = 0;
        emit PauserAddressRemoved(_pauserAddress);
    }
    
    function pause() external onlyOracleCouncilAndOwner {
        _pause();
    }

    function unpause() external onlyOracleCouncilAndOwner {
        _unpause();
    }

    // External view functions ////////////////////////////////////////

    function isActiveMarket(address _marketAddress) public view returns (bool) {
        return _activeMarkets.contains(_marketAddress);
    }

    function numberOfActiveMarkets() external view returns (uint) {
        return _activeMarkets.elements.length;
    }

    function getActiveMarketAddress(uint _index) external view returns (address) {
        return _activeMarkets.elements[_index];
    }

    function isPauserAddress(address _pauser) external view returns (bool) {
        return pauserIndex[_pauser] > 0;
    }

    // Internal functions //////////////////////////////////////////////
 
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
