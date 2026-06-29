// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../types/LaunchpadProposal.sol";

contract LaunchpadState {
    mapping(uint256 => ProposalState) internal _proposals;
}
