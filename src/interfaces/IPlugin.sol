// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ILaunchpadViewer.sol";

interface IPlugin {
    struct DepositInfo {
        uint256 proposalId;
        address depositor;
        uint256 outcome;
        uint256 amount;
    }

    struct WithdrawInfo {
        uint256 proposalId;
        address withdrawer;
        uint256 outcome;
        uint256 amount;
        uint256 remainingBalance;
    }

    function beforeDeposit(DepositInfo calldata deposit, bytes calldata args) external;

    function beforeWithdraw(WithdrawInfo calldata withdraw, bytes calldata args) external;

    function checkProposal(ILaunchpadViewer viewer, uint256 proposalId, bytes calldata args)
        external
        returns (bool readyToLaunch);

    /// @notice Validate plugin parameters during proposal creation
    /// @param args ABI-encoded plugin parameters
    /// @dev MUST revert if parameters are invalid. Called by Launchpad.propose().
    function checkParameters(bytes calldata args) external view;
}
