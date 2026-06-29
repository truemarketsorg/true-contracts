// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ILaunchpadViewer.sol";

interface ILauncher {
    function launch(ILaunchpadViewer viewer, uint256 proposalId, bytes calldata params)
        external
        returns (address market);

    /// @notice Finalizes a launched market by unpausing pools and enabling trading
    /// @param market The address of the market to finalize
    function finalize(address market) external;

    /// @notice Returns the minimum trading duration required by this launcher
    /// @return The minimum trading duration in seconds
    function minimumTradingDuration() external view returns (uint256);
}
