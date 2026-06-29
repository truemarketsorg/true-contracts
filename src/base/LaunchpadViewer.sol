// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../types/LaunchpadProposal.sol";
import "../interfaces/ILaunchpadViewer.sol";
import "./LaunchpadState.sol";

abstract contract LaunchpadViewer is LaunchpadState, ILaunchpadViewer {
    using ProposalDepositStateLibrary for ProposalDepositState;

    /// @notice Payment token wired into the launchpad at initialization time.
    /// @dev Implemented by the concrete Launchpad contract as a public state variable.
    function paymentToken() external view virtual returns (address);

    function proposalDepositors(uint256 proposalId) external view returns (address[] memory) {
        return _proposals[proposalId].depositState.depositorsArray();
    }

    function proposalOutcomes(uint256 proposalId) external view returns (uint256[] memory) {
        return _proposals[proposalId].depositState.outcomesArray();
    }

    function proposalOutcomeDeposits(uint256 proposalId, uint256 outcome) external view returns (uint256) {
        return _proposals[proposalId].depositState.outcomeDeposits[outcome];
    }

    function proposalDeposits(uint256 proposalId, address depositor, uint256 outcome) external view returns (uint256) {
        return _proposals[proposalId].depositState.deposits[depositor][outcome];
    }

    function proposalTotalDeposits(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].depositState.totalDeposits;
    }

    function proposalPhase(uint256 proposalId) external view returns (ProposalPhase) {
        return _proposalPhase(proposalId);
    }

    function proposalCreator(uint256 proposalId) external view returns (address) {
        return _proposals[proposalId].proposal.creator;
    }

    function proposalMarket(uint256 proposalId) external view returns (address) {
        return _proposals[proposalId].market;
    }

    function proposalDistributorRef(uint256 proposalId) external view returns (bytes32) {
        return _proposals[proposalId].proposal.distributorRef;
    }

    function _proposalPhase(uint256 proposalId) internal view returns (ProposalPhase) {
        ProposalPhase phase = _proposals[proposalId].phase;

        if (phase == ProposalPhase.Live) {
            if (block.timestamp > _proposals[proposalId].proposal.endTime) {
                return ProposalPhase.Failed;
            }
        }

        return phase;
    }
}
