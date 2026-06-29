// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ILaunchpadViewer.sol";

interface IDistributor {
    // thrown when the proposal is not launched
    error ProposalNotLaunched();

    event Erc20Distributed(
        uint256 indexed proposalId, address indexed market, address indexed receiver, address token, uint256 amount
    );

    event Erc721Distributed(
        uint256 indexed proposalId, address indexed market, address indexed receiver, address erc721, uint256 id
    );

    event Erc1155Distributed(
        uint256 indexed proposalId,
        address indexed market,
        address indexed receiver,
        address erc1155,
        uint256 id,
        uint256 amount
    );

    event TokensSwept(address indexed token, address indexed to, uint256 amount);

    function distribute(ILaunchpadViewer viewer, uint256 proposalId, uint256 distributable) external;
}
