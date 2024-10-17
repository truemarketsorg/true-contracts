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
// internal
import "./interfaces/ITruthMarketManager.sol";
import "./interfaces/ITruthMarket.sol";
import "./interfaces/IEscalation.sol";
import "./BondConstants.sol";

contract OracleBonds is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    
    // State ////////////////////////////////////////////////////////

    struct MarketBond {
        uint totalDepositedMarketBond;
        uint totalMarketBond;
        uint resolverBond;
        uint disputorsTotalBond;
        uint disputorsCount;
        uint escalatedDisputorBond;
        mapping(address => uint) disputorBond;
    }

    ITruthMarketManager public marketManager;

    mapping(address => MarketBond) public marketBond;

    // Events ////////////////////////////////////////////////////////

    event ResolverBondSent(address market, address resolver, uint amount);
    event DisputorBondSent(address market, address disputor, uint amount);
    event BondTransferredFromMarketBondToUser(address market, address account, uint amount);
    event NewOracleCouncilAddress(address oracleCouncil);
    event NewManagerAddress(address managerAddress);
    event NewStakingThalesAddress(address stakingThales);
    event EscalatedDisputorBondSent(address market, address escalatedDisputor, uint amount);
    event BondTransferredFromMarketBondToSafeBox(address market, uint amount, uint bondReduced, address reduceAddress);
    event OpenDisputeBondTransferredFromMarketToDisputor(address market, address disputor, uint amount);
    
    // Errors ////////////////////////////////////////////////////////

    error NotOracleCouncilAddressAndManagerAndOwner();
    error InvalidAddress();
    error InvalidMarket(address _market);
    error InvalidMarketManager();
    error InvalidOracleCouncilAddress();
    error NotAuthorizedMarketAction();
    error InvalidBondAmount();
    error InsufficientMarketBond();
    error InvalidBondType(uint256 _bondType);

    // Modifiers ////////////////////////////////////////////////////////

    modifier onlyOracleCouncilManagerAndOwner() {
        if (msg.sender != marketManager.oracleCouncilAddress() &&
            msg.sender != address(marketManager) &&
            msg.sender != owner()) {
            revert NotOracleCouncilAddressAndManagerAndOwner();
        }
        if (address(marketManager) == address(0)) {
            revert InvalidMarketManager();
        }
        if (marketManager.oracleCouncilAddress() == address(0)) {
            revert InvalidOracleCouncilAddress();
        }
        _;
    }

    modifier onlyAuthorized(address _market) {
        if (!(msg.sender == marketManager.oracleCouncilAddress() ||
            msg.sender == address(marketManager) ||
            msg.sender == owner() ||
            (msg.sender == _market && marketManager.isActiveMarket(_market)))) {
            revert NotAuthorizedMarketAction();
        }
        if (address(marketManager) == address(0)) {
            revert InvalidMarketManager();
        }
        if (marketManager.oracleCouncilAddress() == address(0)) {
            revert InvalidOracleCouncilAddress();
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

    // different deposit functions to flag the bond amount : resolver
    function sendResolverBondToMarket(
        address _market,
        address _resolverAddress,
        uint _amount
    ) external onlyOracleCouncilManagerAndOwner nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        // in case the creator is the resolver, move the bond to the resolver
        marketBond[_market].resolverBond = _amount;
        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond + _amount;
        marketBond[_market].totalDepositedMarketBond = marketBond[_market].totalDepositedMarketBond + _amount;
        _transferToMarketBond(_resolverAddress, _amount);
        emit ResolverBondSent(_market, _resolverAddress, _amount);
    }

    // different deposit functions to flag the bond amount : disputor
    function sendDisputorBondToMarket(
        address _market,
        address _disputorAddress,
        uint _amount
    ) external onlyOracleCouncilManagerAndOwner nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);

        // if it is first dispute for the disputor, the counter is increased
        if (marketBond[_market].disputorBond[_disputorAddress] == 0) {
            marketBond[_market].disputorsCount = marketBond[_market].disputorsCount + 1;
        }
        marketBond[_market].disputorBond[_disputorAddress] = marketBond[_market].disputorBond[_disputorAddress] + _amount;
        marketBond[_market].disputorsTotalBond = marketBond[_market].disputorsTotalBond + _amount;
        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond + _amount;
        marketBond[_market].totalDepositedMarketBond = marketBond[_market].totalDepositedMarketBond + _amount;
        _transferToMarketBond(_disputorAddress, _amount);
        emit DisputorBondSent(_market, _disputorAddress, _amount);
    }

    function sendEscalatedDisputorBondToMarket(
        address _market,
        address _escalatedDisputorAddress,
        uint _amount
    ) external onlyOracleCouncilManagerAndOwner nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        
        marketBond[_market].escalatedDisputorBond = _amount;
        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond + _amount;
        marketBond[_market].totalDepositedMarketBond = marketBond[_market].totalDepositedMarketBond + _amount;
        _transferToMarketBond(_escalatedDisputorAddress, _amount);
        emit EscalatedDisputorBondSent(_market, _escalatedDisputorAddress, _amount);
    }

    function issueBondsBackToEscalatedDisputor(address _market) external onlyAuthorized(_market) nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        
        uint escalatedDisputorBond = marketBond[_market].escalatedDisputorBond;
        if (marketBond[_market].totalMarketBond < escalatedDisputorBond) revert InsufficientMarketBond();

        address escalatedDisputorAddress = IEscalation(marketManager.escalationAddress()).getEscalatedDispute(_market).escalatedDisputorAddress;

        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - escalatedDisputorBond;
        marketBond[_market].escalatedDisputorBond = 0;

        _transferBondFromMarket(escalatedDisputorAddress, escalatedDisputorBond);
        emit BondTransferredFromMarketBondToUser(_market, escalatedDisputorAddress, escalatedDisputorBond);
    }

    function sendBondFromMarketToSafeBox(
        address _market,
        uint _bondToReduce,
        address _disputorAddress
    ) external onlyAuthorized(_market) nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        if (_bondToReduce < BondConstants.RESOLVER_BOND || _bondToReduce > BondConstants.ESCALATED_DISPUTOR_BOND) {
            revert InvalidBondType(_bondToReduce);
        }
        
        uint amountToTransfer;

        if (_bondToReduce == BondConstants.RESOLVER_BOND) {
            amountToTransfer = marketBond[_market].resolverBond;
            marketBond[_market].resolverBond = 0;
        } else if (_bondToReduce == BondConstants.DISPUTOR_BOND) {
            amountToTransfer = marketBond[_market].disputorBond[_disputorAddress];
            marketBond[_market].disputorBond[_disputorAddress] = 0;
            marketBond[_market].disputorsTotalBond = marketBond[_market].disputorsTotalBond - amountToTransfer;
            if (amountToTransfer > 0) {
                marketBond[_market].disputorsCount = marketBond[_market].disputorsCount - 1;
            }
        } else if (_bondToReduce == BondConstants.ESCALATED_DISPUTOR_BOND) {
            amountToTransfer = marketBond[_market].escalatedDisputorBond;
            marketBond[_market].escalatedDisputorBond = 0;
        }

        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - amountToTransfer;
        _transferBondFromMarket(marketManager.safeBoxAddress(), amountToTransfer);
        emit BondTransferredFromMarketBondToSafeBox(_market, amountToTransfer, _bondToReduce, _disputorAddress);
    }

    function issueBondsBackToResolver(address _market) external onlyAuthorized(_market) nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        uint totalIssuedBack;
        if (marketBond[_market].totalMarketBond >= marketBond[_market].resolverBond) {
            marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - marketBond[_market].resolverBond;
            if (marketBond[_market].resolverBond > 0) {
                totalIssuedBack = marketBond[_market].resolverBond;
                marketBond[_market].resolverBond = 0;
                _transferBondFromMarket(marketManager.resolverAddress(_market), totalIssuedBack);
                emit BondTransferredFromMarketBondToUser(_market, marketManager.resolverAddress(_market), totalIssuedBack);
            }
        }
    }

    function issueBondsBackToDisputor(address _market, address _disputorAddress) external onlyAuthorized(_market) nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        
        uint disputorBond = marketBond[_market].disputorBond[_disputorAddress];
        if (marketBond[_market].totalMarketBond < disputorBond) revert InsufficientMarketBond();

        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - disputorBond;
        marketBond[_market].disputorsTotalBond = marketBond[_market].disputorsTotalBond - disputorBond;
        marketBond[_market].disputorBond[_disputorAddress] = 0;
        
        if (marketBond[_market].disputorsCount > 0) {
            marketBond[_market].disputorsCount = marketBond[_market].disputorsCount - 1;
        }

        _transferBondFromMarket(_disputorAddress, disputorBond);
        emit BondTransferredFromMarketBondToUser(_market, _disputorAddress, disputorBond);
    }

    function sendOpenDisputeBondFromMarketToDisputor(
        address _market,
        address _disputorAddress
    ) external onlyOracleCouncilManagerAndOwner nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        
        uint disputorBond = marketBond[_market].disputorBond[_disputorAddress];
        if (marketBond[_market].totalMarketBond < disputorBond) revert InsufficientMarketBond();

        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - disputorBond;
        marketBond[_market].disputorsTotalBond = marketBond[_market].disputorsTotalBond - disputorBond;
        marketBond[_market].disputorBond[_disputorAddress] = 0;
        
        if (marketBond[_market].disputorsCount > 0) {
            marketBond[_market].disputorsCount = marketBond[_market].disputorsCount - 1;
        }

        _transferBondFromMarket(_disputorAddress, disputorBond);
        emit OpenDisputeBondTransferredFromMarketToDisputor(_market, _disputorAddress, disputorBond);
    }

    function setManagerAddress(address _managerAddress) external onlyOwner {
        if (_managerAddress == address(0)) revert InvalidMarketManager();
        marketManager = ITruthMarketManager(_managerAddress);
        emit NewManagerAddress(_managerAddress);
    }

    function setPaused(bool _setPausing) external onlyOwner {
        if (_setPausing) {
            _pause();
        } else {
            _unpause();
        }
    }

    // External view functions //////////////////////////////////////// 

    function getTotalDepositedBondAmountForMarket(address _market) external view returns (uint) {
        return marketBond[_market].totalDepositedMarketBond;
    }

    function getClaimedBondAmountForMarket(address _market) external view returns (uint) {
        return marketBond[_market].totalDepositedMarketBond - marketBond[_market].totalMarketBond;
    }

    function getClaimableBondAmountForMarket(address _market) external view returns (uint) {
        return marketBond[_market].totalMarketBond;
    }

    function getDisputorBondForMarket(address _market, address _disputorAddress) external view returns (uint) {
        return marketBond[_market].disputorBond[_disputorAddress];
    }

    function getResolverBondForMarket(address _market) external view returns (uint) {
        return marketBond[_market].resolverBond;
    }

    function getEscalatedDisputorBondForMarket(address _market) external view returns (uint) {
        return marketBond[_market].escalatedDisputorBond;
    }
    
    // Internal functions //////////////////////////////////////////////

    function _transferToMarketBond(address _account, uint _amount) internal whenNotPaused {
        if (_account == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidBondAmount();
        IERC20Upgradeable(marketManager.paymentToken()).safeTransferFrom(_account, address(this), _amount);
    }

    function _transferBondFromMarket(address _account, uint _amount) internal whenNotPaused {
        if (_account == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidBondAmount();
        IERC20Upgradeable(marketManager.paymentToken()).safeTransfer(_account, _amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}