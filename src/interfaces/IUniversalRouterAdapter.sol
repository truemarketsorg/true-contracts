// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IUniversalRouterAdapter {
    error BatchExecuteNotSupported();
    error CommandNotWhitelisted();

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
