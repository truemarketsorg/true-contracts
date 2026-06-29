// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./LaunchpadHook.sol";
import "../interfaces/ILaunchpad.sol";
import "../interfaces/IPlugin.sol";

struct Proposal {
    bytes params;
    uint256 endTime;
    bytes32 launcherRef;
    bytes32 distributorRef;
    HookBinding[] hookBindings;
    address creator;
}

struct ProposalDepositState {
    // tracked to enumerate refunds/distribution
    EnumerableSet.AddressSet depositors;
    // outcomes with non-zero balance
    EnumerableSet.UintSet outcomes;
    // outcome => total deposits for that outcome
    mapping(uint256 => uint256) outcomeDeposits;
    // depositor => outcome => amount
    mapping(address => mapping(uint256 => uint256)) deposits;
    // sum across outcomes (used by launch hooks)
    uint256 totalDeposits;
    // number of outcomes with non-zero balance per depositor
    mapping(address => uint256) activeOutcomeCount;
}

enum ProposalPhase {
    Uninitialized,
    Live,
    Launched,
    Distributed,
    Failed,
    // emitted when failed in deferred distribution
    ManualDistributionNeeded,
    // emitted when funds are withdrawn from a proposal which is in the ManualDistributionNeeded phase
    FundsWithdrawn
}

struct ProposalState {
    Proposal proposal;
    ProposalDepositState depositState;
    ProposalPhase phase;
    address market;
    uint256 failedDistributionAttempts;
    bool distributed;
    bool feePaid;
}

library ProposalLibrary {
    /// @notice Runs all BeforeDeposit hooks for a proposal.
    /// @dev Reverts if any BeforeDeposit hook references an unregistered module (address(0)).
    /// This protects users from depositing into proposals where hooks cannot execute properly.
    /// Unlike BeforeWithdraw hooks (which skip unregistered modules to ensure fund recovery),
    /// BeforeDeposit hooks block new deposits when modules are missing.
    function runBeforeDepositHooks(
        Proposal storage self,
        IPlugin.DepositInfo memory info,
        mapping(bytes32 => address) storage moduleRegistry
    ) internal {
        HookBinding[] storage bindings = self.hookBindings;
        uint256 length = bindings.length;
        for (uint256 i; i < length; i++) {
            HookBinding storage binding = bindings[i];
            if (binding.hookType == HookType.BeforeDeposit) {
                address plugin = moduleRegistry[binding.pluginRef];
                if (plugin == address(0)) {
                    revert ILaunchpad.ModuleNotRegistered(binding.pluginRef);
                }
                IPlugin(plugin).beforeDeposit(info, binding.args);
            }
        }
    }

    function runBeforeWithdrawHooks(
        Proposal storage self,
        IPlugin.WithdrawInfo memory info,
        mapping(bytes32 => address) storage moduleRegistry
    ) internal {
        HookBinding[] storage bindings = self.hookBindings;
        uint256 length = bindings.length;
        for (uint256 i; i < length; i++) {
            HookBinding storage binding = bindings[i];
            if (binding.hookType == HookType.BeforeWithdraw) {
                address plugin = moduleRegistry[binding.pluginRef];
                if (plugin != address(0)) {
                    IPlugin(plugin).beforeWithdraw(info, binding.args);
                }
            }
        }
    }

    /// @notice Runs all CheckProposal hooks for a proposal.
    /// @dev Reverts if any CheckProposal hook references an unregistered module.
    /// @return True only if at least one CheckProposal hook exists AND all hooks pass.
    ///         Returns false if no CheckProposal hooks are configured (proposal requires
    ///         explicit validation hooks to be launchable) or if any hook rejects.
    function runCheckProposalHooks(
        Proposal storage self,
        ILaunchpadViewer viewer,
        uint256 proposalId,
        mapping(bytes32 => address) storage moduleRegistry
    ) internal returns (bool) {
        HookBinding[] storage bindings = self.hookBindings;
        uint256 length = bindings.length;
        uint256 checkHookCount;
        for (uint256 i; i < length; i++) {
            HookBinding storage binding = bindings[i];
            if (binding.hookType == HookType.CheckProposal) {
                address plugin = moduleRegistry[binding.pluginRef];
                if (plugin == address(0)) {
                    revert ILaunchpad.ModuleNotRegistered(binding.pluginRef);
                }
                checkHookCount++;
                if (!IPlugin(plugin).checkProposal(viewer, proposalId, binding.args)) {
                    return false;
                }
            }
        }
        return checkHookCount > 0;
    }
}

library ProposalDepositStateLibrary {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    function addOutcome(ProposalDepositState storage self, uint256 outcome) internal {
        self.outcomes.add(outcome);
    }

    function removeOutcome(ProposalDepositState storage self, uint256 outcome) internal {
        self.outcomes.remove(outcome);
    }

    function addDepositor(ProposalDepositState storage self, address depositor) internal {
        self.depositors.add(depositor);
    }

    function removeDepositor(ProposalDepositState storage self, address depositor) internal {
        self.depositors.remove(depositor);
    }

    function depositorsArray(ProposalDepositState storage self) internal view returns (address[] memory) {
        return self.depositors.values();
    }

    function outcomesArray(ProposalDepositState storage self) internal view returns (uint256[] memory) {
        return self.outcomes.values();
    }
}
