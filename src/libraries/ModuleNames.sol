// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library ModuleNames {
    bytes32 constant LAUNCHER_TRUTH_MARKET_V2 = keccak256("launcher.truth_market_v2");
    bytes32 constant DISTRIBUTOR_COMMUNITY = keccak256("distributor.community");
    bytes32 constant DISTRIBUTOR_WHALES = keccak256("distributor.whales");
    bytes32 constant PLUGIN_BINARY_OUTCOME = keccak256("plugin.binary_outcome");
    bytes32 constant PLUGIN_RESTRICT_DEPOSITOR = keccak256("plugin.restrict_depositor");
    bytes32 constant PLUGIN_RESTRICT_MINIMUM_DEPOSITS = keccak256("plugin.restrict_minimum_deposits");
    bytes32 constant PLUGIN_RESTRICT_MAXIMUM_RATIO_OF_OUTCOME_DEPOSIT =
        keccak256("plugin.restrict_maximum_ratio_of_outcome_deposit");
}
