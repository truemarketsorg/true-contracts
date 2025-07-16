// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAdapterCallbacks {
    // callback msg.sender is not registered strategy contract.
    error NotAuthorized();
    error ExceedPermit2Limit();

    // Always transfers from an external address to the adapter contract.
    // If the token is an ERC4626 vault token, will auto deposit before transfer.
    // Strategy contract can collect tokens from users via this callback.
    function permit2TransferFrom(uint256 fromCommand, address from, uint256 amount, address token)
        external
        returns (uint256 actualAmount);

    // Always transfers from the adapter contract to an external address.
    // If the token is an ERC4626 vault token, will auto redeem before transfer.
    function transferTo(uint256 fromCommand, address to, uint256 amount, address token) external;
}
