// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../types/LaunchpadProposal.sol";

interface ILaunchpadViewer {
    // the depositors for a proposal
    function proposalDepositors(uint256 proposalId) external view returns (address[] memory);

    // the outcomes with non-zero balance
    function proposalOutcomes(uint256 proposalId) external view returns (uint256[] memory);

    // the amount of deposits for an outcome
    function proposalOutcomeDeposits(uint256 proposalId, uint256 outcome) external view returns (uint256);

    // the amount of deposits for a depositor on an outcome
    function proposalDeposits(uint256 proposalId, address depositor, uint256 outcome) external view returns (uint256);

    // sum across outcomes
    function proposalTotalDeposits(uint256 proposalId) external view returns (uint256);

    // the phase of a proposal
    function proposalPhase(uint256 proposalId) external view returns (ProposalPhase);

    // the creator of a proposal
    function proposalCreator(uint256 proposalId) external view returns (address);

    // the market of a proposal
    function proposalMarket(uint256 proposalId) external view returns (address);

    // the distributor module ref of a proposal
    function proposalDistributorRef(uint256 proposalId) external view returns (bytes32);

    // the payment token wired into the launchpad at initialization time
    function paymentToken() external view returns (address);
}
