// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/ILaunchpad.sol";
import "./interfaces/ILaunchpadFactory.sol";
import "./types/LaunchpadProposal.sol";
import "./types/LaunchpadHook.sol";
import "./libraries/Roles.sol";
import "./libraries/LaunchpadFactoryMarketV2.sol";
import "./libraries/LaunchpadFactoryCommunityV2.sol";
import "./libraries/LaunchpadFactoryWhalesV2.sol";
import "./interfaces/ILauncher.sol";

/// @title LaunchpadFactory
/// @notice Factory contract for creating permissionless market proposals with typed interfaces
contract LaunchpadFactory is ILaunchpadFactory, Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    /// @notice Thrown when arguments are invalid
    error InvalidArguments();
    /// @notice Thrown when proposal type is invalid
    error InvalidProposalType();
    /// @notice Thrown when end time is invalid
    error InvalidEndTime();

    ILaunchpad public launchpad;

    uint256 public minimumProposalDuration = 1 hours;

    /// @notice Minimum deposit required per proposal type and payment token
    /// @dev proposalType => paymentToken => minimumDeposit (raw units)
    mapping(ProposalType => mapping(address => uint256)) public minimumDeposits;

    /// @notice Emitted when minimum deposit is updated
    event MinimumDepositUpdated(
        ProposalType indexed proposalType, address indexed paymentToken, uint256 minimumDeposit
    );

    /// @notice Mapping to store proposal specs by ID and type
    mapping(uint256 => CommunityTruthMarketV2Spec) private _communitySpecs;
    mapping(uint256 => WhalesTruthMarketV2Spec) private _whalesSpecs;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the factory
    /// @param launchpad_ Address of the launchpad contract
    function initialize(address launchpad_) external initializer {
        if (launchpad_ == address(0)) {
            revert InvalidArguments();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();

        launchpad = ILaunchpad(launchpad_);
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Set the minimum proposal duration
    /// @param newMinimumProposalDuration The new minimum proposal duration
    function setMinimumProposalDuration(uint256 newMinimumProposalDuration)
        external
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        uint256 oldDuration = minimumProposalDuration;

        minimumProposalDuration = newMinimumProposalDuration;

        emit MinimumProposalDurationUpdated(oldDuration, newMinimumProposalDuration);
    }

    /// @notice Set the minimum deposit for a proposal type and payment token
    /// @param proposalType_ The proposal type
    /// @param paymentToken_ The payment token address (must not be zero)
    /// @param minimumDeposit_ The minimum deposit in raw units (must be > 0)
    function setMinimumDeposit(ProposalType proposalType_, address paymentToken_, uint256 minimumDeposit_)
        external
        onlyRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (paymentToken_ == address(0)) revert InvalidPaymentToken();
        if (minimumDeposit_ == 0) revert InvalidMinimumDeposit();
        minimumDeposits[proposalType_][paymentToken_] = minimumDeposit_;
        emit MinimumDepositUpdated(proposalType_, paymentToken_, minimumDeposit_);
    }

    /// @notice Create a Community market proposal
    /// @param spec The proposal specification
    /// @return proposalId The ID of the created proposal
    function proposeCommunityTruthMarketV2(CommunityTruthMarketV2Spec calldata spec)
        external
        returns (uint256 proposalId)
    {
        _validateProposalDuration(spec.endOfProposal);
        _validateMinimumDeposit(ProposalType.CommunityMarketV2, spec.minimumDeposit);

        // Normalize spec to apply defaults before validation, composition, and storage
        CommunityTruthMarketV2Spec memory normalizedSpec = LaunchpadFactoryCommunityV2.normalizeSpec(spec);

        uint256 minTradingDuration = _getMinimumTradingDuration(ModuleNames.LAUNCHER_TRUTH_MARKET_V2);
        LaunchpadFactoryCommunityV2.validateSpec(normalizedSpec, minTradingDuration);

        Proposal memory proposal = LaunchpadFactoryCommunityV2.composeProposal(normalizedSpec, msg.sender);

        proposalId = launchpad.propose(proposal);

        // Store normalized spec so retrieval matches effective launch parameters
        _communitySpecs[proposalId] = normalizedSpec;

        emit ProposalCreated(proposalId, ProposalType.CommunityMarketV2);
    }

    /// @notice Create a Whales market proposal
    /// @param spec The proposal specification
    /// @return proposalId The ID of the created proposal
    function proposeWhalesTruthMarketV2(WhalesTruthMarketV2Spec calldata spec) external returns (uint256 proposalId) {
        _validateProposalDuration(spec.endOfProposal);
        _validateMinimumDeposit(ProposalType.WhalesMarketV2, spec.minimumDeposit);

        // Normalize spec to apply defaults before validation, composition, and storage
        WhalesTruthMarketV2Spec memory normalizedSpec = LaunchpadFactoryWhalesV2.normalizeSpec(spec);

        uint256 minTradingDuration = _getMinimumTradingDuration(ModuleNames.LAUNCHER_TRUTH_MARKET_V2);
        LaunchpadFactoryWhalesV2.validateSpec(normalizedSpec, minTradingDuration);

        Proposal memory proposal = LaunchpadFactoryWhalesV2.composeProposal(normalizedSpec, msg.sender);

        proposalId = launchpad.propose(proposal);

        // Store normalized spec so retrieval matches effective launch parameters
        _whalesSpecs[proposalId] = normalizedSpec;

        emit ProposalCreated(proposalId, ProposalType.WhalesMarketV2);
    }

    /// @notice Get the Community market spec for a proposal
    /// @param proposalId The proposal ID
    /// @return spec The proposal specification
    function communityTruthMarketV2Spec(uint256 proposalId)
        external
        view
        returns (CommunityTruthMarketV2Spec memory spec)
    {
        spec = _communitySpecs[proposalId];
        if (spec.proposalType != ProposalType.CommunityMarketV2) {
            revert InvalidProposalType();
        }
    }

    /// @notice Get the Whales market spec for a proposal
    /// @param proposalId The proposal ID
    /// @return spec The proposal specification
    function whalesTruthMarketV2Spec(uint256 proposalId) external view returns (WhalesTruthMarketV2Spec memory spec) {
        spec = _whalesSpecs[proposalId];
        if (spec.proposalType != ProposalType.WhalesMarketV2) {
            revert InvalidProposalType();
        }
    }

    function _validateProposalDuration(uint256 endOfProposal) internal view {
        if (endOfProposal <= block.timestamp + minimumProposalDuration) revert InvalidEndTime();
    }

    /// @notice Validate that spec minimum deposit meets requirements
    /// @param proposalType_ The proposal type
    /// @param specMinimumDeposit_ The minimum deposit from the spec
    function _validateMinimumDeposit(ProposalType proposalType_, uint256 specMinimumDeposit_) internal view {
        address paymentToken = address(launchpad.paymentToken());
        uint256 required = minimumDeposits[proposalType_][paymentToken];

        if (required == 0) {
            revert MinimumDepositNotConfigured(proposalType_, paymentToken);
        }

        if (specMinimumDeposit_ < required) {
            revert InvalidMinimumDeposit();
        }
    }

    /// @notice Get minimumTradingDuration from the launcher
    /// @param launcherRef The launcher module reference
    /// @return The minimum trading duration in seconds
    function _getMinimumTradingDuration(bytes32 launcherRef) internal view returns (uint256) {
        address launcher = launchpad.resolveModule(launcherRef);
        if (launcher == address(0)) {
            revert ILaunchpad.ModuleNotRegistered(launcherRef);
        }
        return ILauncher(launcher).minimumTradingDuration();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.DEFAULT_ADMIN_ROLE) {}
}
