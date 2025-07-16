// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IUniversalRouterAdapterStrategy {
    struct PackedApproval {
        address token;
        uint256 amount;
    }

    /// @notice Called before the execute function of the UniversalRouterAdapter
    /// @param command The command type to execute
    /// @param inputs The inputs to execute the command with
    /// @param msgSender The address of the message sender
    /// @return approvals The approvals to increase the allowance for
    /// @return modifiedInputs The modified inputs to execute the command with
    function beforeExecute(uint256 command, bytes calldata inputs, address msgSender)
        external
        returns (PackedApproval[] memory approvals, bytes memory modifiedInputs);
    function afterExecute(uint256 command, bytes calldata inputs, address msgSender) external;
}
