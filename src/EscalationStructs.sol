// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./EscalationEnums.sol";

struct EscalatedDispute {
    address escalatedDisputorAddress;
    string disputeString;
    string escalationProposalId;
    EscalationStatus escalationStatus;
    EscalationResult escalationResult;
    uint256 resultWinningPosition;
    uint256 createdAt;
    uint256 resolvedAt;
    bool isEscalatedDisputorPunished;
    bool isCouncilDisputorPunished;
    bool isOriginalResolverPunished;
}