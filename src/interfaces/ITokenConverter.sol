// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITokenConverter {
    function convertSingleMarket(address market) external;
    function convertTokens(address[] calldata markets) external;
    function setReceiver(address newReceiver) external;
    function withdrawToken(address token, uint256 amount) external;
    function withdrawAllToken(address token) external;
    function receiver() external view returns (address);
}