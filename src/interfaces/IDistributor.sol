// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ILaunchpadViewer.sol";

interface IDistributor {
    event DistributeErc20(uint256 proposalId, address market, address erc20, uint256 amount);
    event DistributeErc721(uint256 proposalId, address market, address erc721, uint256 id);
    event DistributeErc1155(uint256 proposalId, address market, address erc1155, uint256 id, uint256 amount);

    function distribute(ILaunchpadViewer viewer, uint256 proposalId, address market) external;
}
