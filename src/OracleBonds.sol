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
import "./interfaces/IBlacklistable.sol";
import "./BondConstants.sol";

contract OracleBonds is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // State ////////////////////////////////////////////////////////

    struct MarketBond {
        uint256 totalDepositedMarketBond;
        uint256 totalMarketBond;
        uint256 resolverBond;
        uint256 disputorsTotalBond;
        uint256 disputorsCount;
        uint256 escalatedDisputorBond;
        mapping(address => uint256) disputorBond;
    }

    ITruthMarketManager public marketManager;

    mapping(address => MarketBond) public marketBond;

    // Events ////////////////////////////////////////////////////////

    event ResolverBondSent(address market, address resolver, uint256 amount);
    event DisputorBondSent(address market, address disputor, uint256 amount);
    event BondTransferredFromMarketBondToUser(address market, address account, uint256 amount);
    event NewOracleCouncilAddress(address oracleCouncil);
    event NewManagerAddress(address managerAddress);
    event NewStakingThalesAddress(address stakingThales);
    event EscalatedDisputorBondSent(address market, address escalatedDisputor, uint256 amount);
    event BondTransferredFromMarketBondToSafeBox(
        address market, uint256 amount, uint256 bondReduced, address reduceAddress
    );
    event OpenDisputeBondTransferredFromMarketToDisputor(address market, address disputor, uint256 amount);

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
        if (
            msg.sender != marketManager.oracleCouncilAddress() && msg.sender != address(marketManager)
                && msg.sender != owner()
        ) {
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
        if (
            !(
                msg.sender == marketManager.oracleCouncilAddress() || msg.sender == address(marketManager)
                    || msg.sender == owner() || (msg.sender == _market && marketManager.isActiveMarket(_market))
            )
        ) {
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

    /// @notice Initializes the contract
    /// @dev Sets up the contract with default values and initializes inherited contracts
    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    // External functions //////////////////////////////////////////////

    /// @notice Deposits resolver bond for a market
    /// @param _market Address of the market
    /// @param _resolverAddress Address of the resolver
    /// @param _amount Amount of bond to deposit
    function sendResolverBondToMarket(address _market, address _resolverAddress, uint256 _amount)
        external
        onlyOracleCouncilManagerAndOwner
        nonReentrant
    {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        // in case the creator is the resolver, move the bond to the resolver
        marketBond[_market].resolverBond = _amount;
        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond + _amount;
        marketBond[_market].totalDepositedMarketBond = marketBond[_market].totalDepositedMarketBond + _amount;
        _transferToMarketBond(_resolverAddress, _amount);
        emit ResolverBondSent(_market, _resolverAddress, _amount);
    }

    /// @notice Deposits disputor bond for a market
    /// @param _market Address of the market
    /// @param _disputorAddress Address of the disputor
    /// @param _amount Amount of bond to deposit
    function sendDisputorBondToMarket(address _market, address _disputorAddress, uint256 _amount)
        external
        onlyOracleCouncilManagerAndOwner
        nonReentrant
    {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);

        // if it is first dispute for the disputor, the counter is increased
        if (marketBond[_market].disputorBond[_disputorAddress] == 0) {
            marketBond[_market].disputorsCount = marketBond[_market].disputorsCount + 1;
        }
        marketBond[_market].disputorBond[_disputorAddress] =
            marketBond[_market].disputorBond[_disputorAddress] + _amount;
        marketBond[_market].disputorsTotalBond = marketBond[_market].disputorsTotalBond + _amount;
        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond + _amount;
        marketBond[_market].totalDepositedMarketBond = marketBond[_market].totalDepositedMarketBond + _amount;
        _transferToMarketBond(_disputorAddress, _amount);
        emit DisputorBondSent(_market, _disputorAddress, _amount);
    }

    /// @notice Deposits escalated disputor bond for a market
    /// @param _market Address of the market
    /// @param _escalatedDisputorAddress Address of the escalated disputor
    /// @param _amount Amount of bond to deposit
    function sendEscalatedDisputorBondToMarket(address _market, address _escalatedDisputorAddress, uint256 _amount)
        external
        onlyOracleCouncilManagerAndOwner
        nonReentrant
    {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);

        marketBond[_market].escalatedDisputorBond = _amount;
        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond + _amount;
        marketBond[_market].totalDepositedMarketBond = marketBond[_market].totalDepositedMarketBond + _amount;
        _transferToMarketBond(_escalatedDisputorAddress, _amount);
        emit EscalatedDisputorBondSent(_market, _escalatedDisputorAddress, _amount);
    }

    /// @notice Returns bonds to escalated disputor
    /// @param _market Address of the market
    function issueBondsBackToEscalatedDisputor(address _market) external onlyAuthorized(_market) nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);

        uint256 escalatedDisputorBond = marketBond[_market].escalatedDisputorBond;
        if (marketBond[_market].totalMarketBond < escalatedDisputorBond) revert InsufficientMarketBond();

        address escalatedDisputorAddress =
            IEscalation(marketManager.escalationAddress()).getEscalatedDispute(_market).escalatedDisputorAddress;

        marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - escalatedDisputorBond;
        marketBond[_market].escalatedDisputorBond = 0;

        _transferBondFromMarket(escalatedDisputorAddress, escalatedDisputorBond);
        emit BondTransferredFromMarketBondToUser(_market, escalatedDisputorAddress, escalatedDisputorBond);
    }

    /// @notice Transfers bond from market to safe box
    /// @param _market Address of the market
    /// @param _bondToReduce Amount of bond to reduce
    /// @param _disputorAddress Address of the disputor
    function sendBondFromMarketToSafeBox(address _market, uint256 _bondToReduce, address _disputorAddress)
        external
        onlyAuthorized(_market)
        nonReentrant
    {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        if (_bondToReduce < BondConstants.RESOLVER_BOND || _bondToReduce > BondConstants.ESCALATED_DISPUTOR_BOND) {
            revert InvalidBondType(_bondToReduce);
        }

        uint256 amountToTransfer;

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

    /// @notice Returns bonds to resolver
    /// @param _market Address of the market
    function issueBondsBackToResolver(address _market) external onlyAuthorized(_market) nonReentrant {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);
        uint256 totalIssuedBack;
        if (marketBond[_market].totalMarketBond >= marketBond[_market].resolverBond) {
            marketBond[_market].totalMarketBond = marketBond[_market].totalMarketBond - marketBond[_market].resolverBond;
            if (marketBond[_market].resolverBond > 0) {
                totalIssuedBack = marketBond[_market].resolverBond;
                marketBond[_market].resolverBond = 0;
                _transferBondFromMarket(marketManager.resolverAddress(_market), totalIssuedBack);
                emit BondTransferredFromMarketBondToUser(
                    _market, marketManager.resolverAddress(_market), totalIssuedBack
                );
            }
        }
    }

    /// @notice Returns bonds to disputor
    /// @param _market Address of the market
    /// @param _disputorAddress Address of the disputor
    function issueBondsBackToDisputor(address _market, address _disputorAddress)
        external
        onlyAuthorized(_market)
        nonReentrant
    {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);

        uint256 disputorBond = marketBond[_market].disputorBond[_disputorAddress];
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

    /// @notice Transfers open dispute bond from market to disputor
    /// @param _market Address of the market
    /// @param _disputorAddress Address of the disputor
    function sendOpenDisputeBondFromMarketToDisputor(address _market, address _disputorAddress)
        external
        onlyOracleCouncilManagerAndOwner
        nonReentrant
    {
        if (!marketManager.isActiveMarket(_market)) revert InvalidMarket(_market);

        uint256 disputorBond = marketBond[_market].disputorBond[_disputorAddress];
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

    /// @notice Sets the market manager address
    /// @param _managerAddress Address of the market manager contract
    function setManagerAddress(address _managerAddress) external onlyOwner {
        if (_managerAddress == address(0)) revert InvalidMarketManager();
        marketManager = ITruthMarketManager(_managerAddress);
        emit NewManagerAddress(_managerAddress);
    }

    /// @notice Sets the pause state of the contract
    /// @param _setPausing True to pause, false to unpause
    function setPaused(bool _setPausing) external onlyOwner {
        if (_setPausing) {
            _pause();
        } else {
            _unpause();
        }
    }

    // External view functions ////////////////////////////////////////

    /// @notice Gets total deposited bond amount for a market
    /// @param _market Address of the market
    /// @return Total deposited bond amount
    function getTotalDepositedBondAmountForMarket(address _market) external view returns (uint256) {
        return marketBond[_market].totalDepositedMarketBond;
    }

    /// @notice Gets claimed bond amount for a market
    /// @param _market Address of the market
    /// @return Claimed bond amount
    function getClaimedBondAmountForMarket(address _market) external view returns (uint256) {
        return marketBond[_market].totalDepositedMarketBond - marketBond[_market].totalMarketBond;
    }

    /// @notice Gets claimable bond amount for a market
    /// @param _market Address of the market
    /// @return Claimable bond amount
    function getClaimableBondAmountForMarket(address _market) external view returns (uint256) {
        return marketBond[_market].totalMarketBond;
    }

    /// @notice Gets disputor bond amount for a market
    /// @param _market Address of the market
    /// @param _disputorAddress Address of the disputor
    /// @return Disputor bond amount
    function getDisputorBondForMarket(address _market, address _disputorAddress) external view returns (uint256) {
        return marketBond[_market].disputorBond[_disputorAddress];
    }

    /// @notice Gets resolver bond amount for a market
    /// @param _market Address of the market
    /// @return Resolver bond amount
    function getResolverBondForMarket(address _market) external view returns (uint256) {
        return marketBond[_market].resolverBond;
    }

    /// @notice Gets escalated disputor bond amount for a market
    /// @param _market Address of the market
    /// @return Escalated disputor bond amount
    function getEscalatedDisputorBondForMarket(address _market) external view returns (uint256) {
        return marketBond[_market].escalatedDisputorBond;
    }

    // Internal functions //////////////////////////////////////////////

    /// @notice Transfers tokens to market bond
    /// @param _account Address to transfer from
    /// @param _amount Amount to transfer
    function _transferToMarketBond(address _account, uint256 _amount) internal whenNotPaused {
        if (_account == address(0)) revert InvalidAddress();
        IERC20Upgradeable(marketManager.paymentToken()).safeTransferFrom(_account, address(this), _amount);
    }

    /// @notice Transfers bonds from market
    /// @param _account Address to transfer to
    /// @param _amount Amount to transfer
    function _transferBondFromMarket(address _account, uint256 _amount) internal whenNotPaused {
        if (_account == address(0)) revert InvalidAddress();
        IERC20Upgradeable token = IERC20Upgradeable(marketManager.paymentToken());

        bool isBlacklisted = false;
        try IBlacklistable(address(token)).isBlacklisted(_account) returns (bool result) {
            isBlacklisted = result;
        } catch {
            // interface not implemented or call failed, treat as not blacklisted
            isBlacklisted = false;
        }

        if (isBlacklisted) {
            token.safeTransfer(marketManager.safeBoxAddress(), _amount);
            emit BondTransferredFromMarketBondToSafeBox(msg.sender, _amount, 0, _account);
        } else {
            token.safeTransfer(_account, _amount);
        }
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
