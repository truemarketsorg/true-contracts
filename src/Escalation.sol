// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./interfaces/ITruthMarket.sol";
import "./interfaces/ITruthMarketManager.sol";
import "./interfaces/IOracleCouncil.sol";
import "./EscalationEnums.sol";
import "./EscalationStructs.sol";
import {Roles} from "./libraries/Roles.sol";

contract Escalation is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    AccessControlUpgradeable
{
    // State ////////////////////////////////////////////////////////

    ITruthMarketManager public marketManager;
    IOracleCouncil public council;

    mapping(address => EscalatedDispute) public marketToEscalatedDispute;

    // Events ////////////////////////////////////////////////////////

    event NewEscalatedDispute(address market, address escalationDisputor, string disputeString);
    event EscalationProposalIdSet(address market, string escalationProposalId);
    event EscalatedDisputeClosed(address market);
    event AddressesUpdated(address marketManager, address oracleCouncil);
    event EscalationStatusReset(address market);

    // Errors ////////////////////////////////////////////////////////

    error InvalidDisputeString();
    error EscalatedDisputeAlreadyInitialized(EscalationStatus escalationStatus);
    error NoExistingClosedCouncilDispute();
    error MarketSecondChallengePeriodExpired(MarketStatus marketStatus);
    error MarketClosedForDisputes();
    error EscalatedDisputeNotInitialized(EscalationStatus escalationStatus);
    error EscalatedDisputeNotVoting(EscalationStatus escalationStatus);
    error NotOracleCouncil();
    error InvalidOracleCouncil();
    error DisputeNotClosed();
    error NotMarketManager();

    // Modifiers ////////////////////////////////////////////////////////

    modifier onlyOracleCouncilMember() {
        if (!council.isOracleCouncilMember(msg.sender)) revert NotOracleCouncil();
        _;
    }

    // Constructor //////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _marketManager, address _oracleCouncil) public initializer {
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __Ownable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        marketManager = ITruthMarketManager(_marketManager);
        council = IOracleCouncil(_oracleCouncil);
    }

    // External functions //////////////////////////////////////////////

    /// @notice Sets the addresses for market manager and oracle council contracts
    /// @param _marketManager The address of the market manager contract
    /// @param _oracleCouncil The address of the oracle council contract
    function setAddresses(address _marketManager, address _oracleCouncil) external onlyOwner {
        marketManager = ITruthMarketManager(_marketManager);
        council = IOracleCouncil(_oracleCouncil);
        emit AddressesUpdated(_marketManager, _oracleCouncil);
    }

    /// @notice Opens a new escalated dispute for a market
    /// @param _market The address of the market to dispute
    /// @param _disputeString The reason for the escalated dispute
    /// @dev Reverts if dispute string is empty, dispute already exists, no closed council dispute exists, or market is not in correct state
    function openEscalatedDispute(address _market, string memory _disputeString) external whenNotPaused {
        if (keccak256(abi.encode(_disputeString)) == keccak256(abi.encode(""))) revert InvalidDisputeString();
        if (marketToEscalatedDispute[_market].escalationStatus != EscalationStatus.None) {
            revert EscalatedDisputeAlreadyInitialized(marketToEscalatedDispute[_market].escalationStatus);
        }
        if (!council.isMarketLastClosedDisputeExists(_market)) revert NoExistingClosedCouncilDispute();

        MarketStatus marketStatus = ITruthMarket(_market).getCurrentStatus();
        if (marketStatus != MarketStatus.SetByCouncil && marketStatus != MarketStatus.ResetByCouncil) {
            revert MarketSecondChallengePeriodExpired(marketStatus);
        }

        if (!council.isMarketClosedForDisputes(_market)) revert DisputeNotClosed();

        EscalatedDispute memory newEscalatedDispute = EscalatedDispute({
            escalatedDisputorAddress: msg.sender,
            disputeString: _disputeString,
            escalationProposalId: "",
            escalationStatus: EscalationStatus.Initialized,
            escalationResult: EscalationResult.None,
            createdAt: block.timestamp,
            resolvedAt: 0,
            resultWinningPosition: 0,
            isEscalatedDisputorPunished: false,
            isCouncilDisputorPunished: false,
            isOriginalResolverPunished: false
        });

        marketToEscalatedDispute[_market] = newEscalatedDispute;
        marketManager.escalateDisputeMarket(_market, msg.sender);
        emit NewEscalatedDispute(_market, msg.sender, _disputeString);
    }

    /// @notice Sets the proposal ID for an escalated dispute
    /// @param _market The address of the market with the dispute
    /// @param _escalationProposalId The ID of the escalation proposal
    /// @dev Only callable by addresses with OPERATOR_ROLE. Reverts if dispute not in initialized state
    function setEscalationProposalId(address _market, string memory _escalationProposalId)
        external
        onlyRole(Roles.OPERATOR_ROLE)
    {
        if (marketToEscalatedDispute[_market].escalationStatus != EscalationStatus.Initialized) {
            revert EscalatedDisputeNotInitialized(marketToEscalatedDispute[_market].escalationStatus);
        }

        marketToEscalatedDispute[_market].escalationProposalId = _escalationProposalId;
        marketToEscalatedDispute[_market].escalationStatus = EscalationStatus.Voting;
        marketToEscalatedDispute[_market].createdAt = block.timestamp;

        emit EscalationProposalIdSet(_market, _escalationProposalId);
    }

    /// @notice Resolves an escalated dispute with the specified outcome
    /// @param _market The address of the market to resolve
    /// @param _isResultReset Whether to reset the market
    /// @param _isResultAccept Whether to accept the proposed result
    /// @param _winningPosition The winning position if result is accepted
    /// @param _punishEscalatedDisputor Whether to punish the escalated disputor
    /// @param _punishCouncilDisputor Whether to punish the council disputor
    /// @param _punishOriginalResolver Whether to punish the original resolver
    /// @dev Only callable by addresses with OPERATOR_ROLE. Reverts if dispute not in voting state
    function resolveEscalatedDispute(
        address _market,
        bool _isResultReset,
        bool _isResultAccept,
        uint256 _winningPosition,
        bool _punishEscalatedDisputor,
        bool _punishCouncilDisputor,
        bool _punishOriginalResolver
    ) external onlyRole(Roles.OPERATOR_ROLE) {
        if (marketToEscalatedDispute[_market].escalationStatus != EscalationStatus.Voting) {
            revert EscalatedDisputeNotVoting(marketToEscalatedDispute[_market].escalationStatus);
        }

        marketToEscalatedDispute[_market].resolvedAt = block.timestamp;
        marketToEscalatedDispute[_market].escalationStatus = EscalationStatus.Resolved;

        marketToEscalatedDispute[_market].isEscalatedDisputorPunished = _punishEscalatedDisputor;
        marketToEscalatedDispute[_market].isCouncilDisputorPunished = _punishCouncilDisputor;
        marketToEscalatedDispute[_market].isOriginalResolverPunished = _punishOriginalResolver;

        if (_isResultReset) {
            // ACCEPT & RESET MARKET
            marketToEscalatedDispute[_market].escalationResult = EscalationResult.Reset;
            marketManager.resetMarketByEscalation(_market);
        } else if (_isResultAccept) {
            // ACCEPT & RESULT
            marketToEscalatedDispute[_market].escalationResult = EscalationResult.Accepted;
            marketToEscalatedDispute[_market].resultWinningPosition = _winningPosition;
            marketManager.resolveMarketByEscalation(_market, _winningPosition);
        } else {
            // REJECT
            marketToEscalatedDispute[_market].escalationResult = EscalationResult.Rejected;

            IOracleCouncil.Dispute memory lastClosedDispute = council.getLastClosedDispute(_market);
            if (lastClosedDispute.disputeCode == 2) {
                // OC DISPUTE RESULT: RESET MARKET
                marketManager.resetMarketByEscalation(_market);
            } else {
                // OC DISPUTE RESULT: RESOLVE MARKET
                uint256 lastClosedDisputeWinningPosition = lastClosedDispute.winningPosition;
                marketToEscalatedDispute[_market].resultWinningPosition = lastClosedDisputeWinningPosition;
                marketManager.resolveMarketByEscalation(_market, lastClosedDisputeWinningPosition);
            }
        }

        emit EscalatedDisputeClosed(_market);
    }

    /// @notice Resets the escalation status of a market
    /// @param _market The address of the market to reset
    /// @dev Only callable by the market manager contract
    function resetEscalationStatus(address _market) external {
        if (msg.sender != address(marketManager)) revert NotMarketManager();
        marketToEscalatedDispute[_market].escalationStatus = EscalationStatus.None;
        emit EscalationStatusReset(_market);
    }

    /// @notice Pauses all escalation operations
    /// @dev Only callable by addresses with PAUSER_ROLE
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all escalation operations
    /// @dev Only callable by addresses with PAUSER_ROLE
    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // External view functions ////////////////////////////////////////

    /// @notice Checks if a market has an open escalation
    /// @param _market The address of the market to check
    /// @return bool True if the market has an open escalation
    function isEscalationOpen(address _market) external view returns (bool) {
        return marketToEscalatedDispute[_market].escalationStatus != EscalationStatus.None;
    }

    /// @notice Gets the escalated dispute details for a market
    /// @param _market The address of the market to get dispute details for
    /// @return EscalatedDispute The dispute details
    function getEscalatedDispute(address _market) external view returns (EscalatedDispute memory) {
        return marketToEscalatedDispute[_market];
    }

    // Internal functions //////////////////////////////////////////////

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
