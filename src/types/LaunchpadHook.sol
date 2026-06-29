// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

enum HookType {
    BeforeDeposit,
    BeforeWithdraw,
    CheckProposal
}

struct HookBinding {
    HookType hookType;
    bytes32 pluginRef;
    bytes args;
}
