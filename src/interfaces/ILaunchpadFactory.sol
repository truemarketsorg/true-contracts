// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../types/LaunchpadTruthMarketV2.sol";

/// @title ILaunchpadFactory
/// @notice Factory interface for creating permissionless market proposals
interface ILaunchpadFactory {
    /// @notice Thrown when minimum deposit is not configured for a proposal type and token
    error MinimumDepositNotConfigured(ProposalType proposalType, address paymentToken);

    /// @notice Thrown when spec minimum deposit is below required minimum
    error InvalidMinimumDeposit();

    /// @notice Thrown when payment token address is zero
    error InvalidPaymentToken();

    /// @notice Supported proposal types (None = 0 is an invalid sentinel to prevent zero-value bypass)
    enum ProposalType {
        None,
        CommunityMarketV2,
        WhalesMarketV2
    }

    /// @notice Emitted when a new proposal is created
    event ProposalCreated(uint256 proposalId, ProposalType proposalType);
    /// @notice Emitted when the minimum proposal duration is updated
    event MinimumProposalDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Specification for Community market proposals
    struct CommunityTruthMarketV2Spec {
        ProposalType proposalType; // always CommunityMarketV2
        uint256 endOfProposal;
        uint256 minimumDeposit;
        uint256 maxRatioThreshold; // 0 = disabled
        TruthMarketV2Params marketParams;
    }

    /// @notice Specification for Whales market proposals
    struct WhalesTruthMarketV2Spec {
        ProposalType proposalType; // always WhalesMarketV2
        uint256 endOfProposal;
        uint256 minimumDeposit;
        uint256 maxRatioThreshold; // 0 = disabled
        address[] whitelist; // approved depositors
        TruthMarketV2Params marketParams;
    }

    /// @notice Create a Community market proposal
    /// @param spec The proposal specification
    /// @return proposalId The ID of the created proposal
    function proposeCommunityTruthMarketV2(CommunityTruthMarketV2Spec calldata spec)
        external
        returns (uint256 proposalId);

    /// @notice Create a Whales market proposal
    /// @param spec The proposal specification
    /// @return proposalId The ID of the created proposal
    function proposeWhalesTruthMarketV2(WhalesTruthMarketV2Spec calldata spec) external returns (uint256 proposalId);

    /// @notice Get the Community market spec for a proposal
    /// @param proposalId The proposal ID
    /// @return spec The proposal specification
    function communityTruthMarketV2Spec(uint256 proposalId)
        external
        view
        returns (CommunityTruthMarketV2Spec memory spec);

    /// @notice Get the Whales market spec for a proposal
    /// @param proposalId The proposal ID
    /// @return spec The proposal specification
    function whalesTruthMarketV2Spec(uint256 proposalId) external view returns (WhalesTruthMarketV2Spec memory spec);

    /// @notice Set the minimum proposal duration
    /// @param newMinimumProposalDuration The new minimum proposal duration
    function setMinimumProposalDuration(uint256 newMinimumProposalDuration) external;
}
