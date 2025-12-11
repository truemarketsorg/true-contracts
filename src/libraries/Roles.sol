// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Roles {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // v4 hook
    bytes32 public constant V4_HOOK_ROLE = keccak256("V4_HOOK_ROLE");

    // order management
    bytes32 public constant ORDER_RESOLVER_ROLE = keccak256("ORDER_RESOLVER_ROLE");
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");
    bytes32 public constant TOKEN_RESCUER_ROLE = keccak256("TOKEN_RESCUER_ROLE");

    // recipient fee management
    bytes32 public constant RECIPIENTS_MANAGER_ROLE = keccak256("RECIPIENTS_MANAGER_ROLE");
}
