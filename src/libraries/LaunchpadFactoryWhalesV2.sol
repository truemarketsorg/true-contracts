// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../interfaces/ILaunchpadFactory.sol";
import "../types/LaunchpadProposal.sol";
import "./LaunchpadFactoryMarketV2.sol";
import "./ModuleNames.sol";

/// @title Launchpad Factory Whales V2 Library
/// @notice Whales market specific logic for Launchpad factory
library LaunchpadFactoryWhalesV2 {
    /// @notice Thrown when whitelist is empty
    error EmptyWhitelist();

    /// @notice Normalize Whales market specification by applying defaults
    /// @param spec The specification to normalize (calldata)
    /// @return normalized The normalized specification (memory copy)
    function normalizeSpec(ILaunchpadFactory.WhalesTruthMarketV2Spec calldata spec)
        internal
        pure
        returns (ILaunchpadFactory.WhalesTruthMarketV2Spec memory normalized)
    {
        normalized = spec;
        LaunchpadFactoryMarketV2.normalizeParams(normalized.marketParams);

        if (normalized.maxRatioThreshold == 0) {
            // 99.99% - required to prevent InvalidPrice() in SingleSideLPDistributor
            normalized.maxRatioThreshold = 9999;
        }
    }

    /// @notice Validate Whales market specification
    /// @param spec The specification to validate
    function validateSpec(ILaunchpadFactory.WhalesTruthMarketV2Spec memory spec, uint256 minimumTradingDuration)
        internal
        pure
    {
        if (spec.proposalType != ILaunchpadFactory.ProposalType.WhalesMarketV2) {
            revert LaunchpadFactoryMarketV2.InvalidProposalType();
        }

        if (spec.whitelist.length == 0) {
            revert EmptyWhitelist();
        }

        LaunchpadFactoryMarketV2.validateCommon(spec.marketParams, spec.endOfProposal, minimumTradingDuration);
    }

    /// @notice Compose Whales market proposal
    /// @dev Assumes spec is already normalized via normalizeSpec()
    /// @param spec The specification (must be pre-normalized)
    /// @param creator Address of the proposal creator
    /// @return proposal The composed proposal
    function composeProposal(ILaunchpadFactory.WhalesTruthMarketV2Spec memory spec, address creator)
        internal
        pure
        returns (Proposal memory proposal)
    {
        // Create base proposal (params must be pre-normalized)
        proposal = LaunchpadFactoryMarketV2.createBaseProposal(
            creator, ModuleNames.DISTRIBUTOR_WHALES, spec.marketParams, spec.endOfProposal
        );

        // Compose hook bindings
        // 6 hooks: outcome restrict (before), depositor whitelist (before), min deposit (before),
        //          min deposit (withdraw), min deposit (check), max ratio
        HookBinding[] memory hooks = new HookBinding[](6);

        hooks[0] =
            HookBinding({hookType: HookType.BeforeDeposit, pluginRef: ModuleNames.PLUGIN_BINARY_OUTCOME, args: ""});

        // Include depositor restriction
        hooks[1] = HookBinding({
            hookType: HookType.BeforeDeposit,
            pluginRef: ModuleNames.PLUGIN_RESTRICT_DEPOSITOR,
            args: abi.encode(spec.whitelist)
        });

        // Per-transaction minimum: 1% of minimumDeposit, floored to 1 to prevent zero threshold.
        // NOTE: When minimumDeposit < 100, perTxMinimum = 1, which only blocks 0-amount deposits
        // (already rejected by Launchpad). The 1% dust protection is only meaningful for minimumDeposit >= 100.
        uint256 perTxMinimum = spec.minimumDeposit / 100;
        if (perTxMinimum == 0) perTxMinimum = 1;

        // Minimum deposit restriction with 1% of the minimum deposit
        hooks[2] = HookBinding({
            hookType: HookType.BeforeDeposit,
            pluginRef: ModuleNames.PLUGIN_RESTRICT_MINIMUM_DEPOSITS,
            args: abi.encode(perTxMinimum)
        });

        // Minimum withdrawal restriction: remainingBalance == 0 OR remainingBalance >= per-deposit min
        hooks[3] = HookBinding({
            hookType: HookType.BeforeWithdraw,
            pluginRef: ModuleNames.PLUGIN_RESTRICT_MINIMUM_DEPOSITS,
            args: abi.encode(perTxMinimum)
        });

        // Include minimum deposit restriction with check proposal hook
        hooks[4] = HookBinding({
            hookType: HookType.CheckProposal,
            pluginRef: ModuleNames.PLUGIN_RESTRICT_MINIMUM_DEPOSITS,
            args: abi.encode(spec.minimumDeposit)
        });

        // maxRatioThreshold must be pre-normalized (defaults to 9999 if was 0)
        hooks[5] = HookBinding({
            hookType: HookType.CheckProposal,
            pluginRef: ModuleNames.PLUGIN_RESTRICT_MAXIMUM_RATIO_OF_OUTCOME_DEPOSIT,
            args: abi.encode(spec.maxRatioThreshold)
        });

        proposal.hookBindings = hooks;
    }
}
