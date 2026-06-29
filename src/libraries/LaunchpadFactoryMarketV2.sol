// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../interfaces/ILaunchpadFactory.sol";
import "../types/LaunchpadProposal.sol";
import "../types/LaunchpadTruthMarketV2.sol";
import "./ModuleNames.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title Launchpad Factory MarketV2 Library
/// @notice Shared logic for Launchpad factory MarketV2 operations
library LaunchpadFactoryMarketV2 {
    /// @notice Thrown when proposal type is invalid
    error InvalidProposalType();
    /// @notice Thrown when question is empty
    error EmptyQuestion();
    /// @notice Thrown when trading end time is invalid
    error InvalidTradingEndTime();
    /// @notice Thrown when market source is empty
    error EmptySource();
    /// @notice Thrown when symbol format is invalid
    error InvalidSymbolFormat(string symbol);
    /// @notice Thrown when yes and no symbols are identical
    error DuplicateSymbols(string symbol);
    /// @notice Thrown when fee exceeds maximum
    error InvalidFee(uint24 fee);
    /// @notice Thrown when tick spacing is out of Uniswap V4 bounds (must be 1..32767)
    error InvalidTickSpacing(int24 tickSpacing);

    /// @notice Validate common parameters across all market types
    /// @param params Market parameters to validate
    /// @param endOfProposal End time for proposal

    function validateCommon(TruthMarketV2Params memory params, uint256 endOfProposal, uint256 minimumTradingDuration)
        internal
        pure
    {
        // market description cannot be empty
        if (bytes(params.question).length == 0) revert EmptyQuestion();
        if (bytes(params.source).length == 0) revert EmptySource();

        // Validate symbol format (mirrors TruthMarketManager._isValidSymbol, also rejects empty)
        if (!_isValidSymbol(params.outcomeSymbolYes)) revert InvalidSymbolFormat(params.outcomeSymbolYes);
        if (!_isValidSymbol(params.outcomeSymbolNo)) revert InvalidSymbolFormat(params.outcomeSymbolNo);

        // Check for duplicate symbols
        if (keccak256(bytes(params.outcomeSymbolYes)) == keccak256(bytes(params.outcomeSymbolNo))) {
            revert DuplicateSymbols(params.outcomeSymbolYes);
        }

        // Validate fee
        if (params.fee > 10000) revert InvalidFee(params.fee);

        // Validate tick spacing: must be within Uniswap V4 PoolManager bounds.
        // normalizeParams() converts zero to the default (60) before this check.
        if (params.tickSpacing < TickMath.MIN_TICK_SPACING || params.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(params.tickSpacing);
        }

        // Trading must be open for at least minimumTradingDuration after proposal ends
        if (params.endOfTrading < endOfProposal + minimumTradingDuration) revert InvalidTradingEndTime();
    }

    /// @notice Normalize market parameters by applying defaults
    /// @dev Modifies params in-place. Call this before validation and composition.
    /// @param params Market parameters to normalize
    function normalizeParams(TruthMarketV2Params memory params) internal pure {
        // TODO: Reward funding will come from a portion of the protocol fee
        // charged on proposal deposits. The fee split ratio is TBD.
        params.rewardToken = address(0);
        params.rewardAmount = 0;

        if (params.fee == 0) {
            params.fee = 3000; // Default to 0.3% fee tier
        }

        if (params.tickSpacing == 0) {
            params.tickSpacing = 60; // Default tick spacing for 0.3% fee tier
        }
    }

    /// @notice Create base proposal structure with common components
    /// @dev Assumes params are already normalized via normalizeParams()
    /// @param creator Address of the proposal creator
    /// @param distributorRef Module registry ref for the distributor
    /// @param params Market parameters (must be pre-normalized)
    /// @param endOfProposal End time for proposal
    /// @return proposal Base proposal structure
    function createBaseProposal(
        address creator,
        bytes32 distributorRef,
        TruthMarketV2Params memory params,
        uint256 endOfProposal
    ) internal pure returns (Proposal memory proposal) {
        // Encode launcher parameters
        bytes memory launcherParams = abi.encode(params);

        proposal = Proposal({
            params: launcherParams,
            endTime: endOfProposal,
            launcherRef: ModuleNames.LAUNCHER_TRUTH_MARKET_V2,
            distributorRef: distributorRef,
            hookBindings: new HookBinding[](0), // Will be extended by specific market libraries
            creator: creator
        });
    }

    /// @notice Validates that a symbol contains only alphanumeric characters, spaces, and hyphens
    /// @dev Mirrors TruthMarketManager._isValidSymbol() validation
    function _isValidSymbol(string memory symbol) private pure returns (bool) {
        bytes memory b = bytes(symbol);
        if (b.length == 0 || b.length > 20) return false;

        for (uint256 i; i < b.length; i++) {
            bytes1 char = b[i];
            if (
                !(char >= 0x30 && char <= 0x39) // 0-9
                    && !(char >= 0x41 && char <= 0x5A) // A-Z
                    && !(char >= 0x61 && char <= 0x7A) // a-z
                    && !(char == 0x20) // space
                    && !(char == 0x2D) // hyphen
            ) return false;
        }
        return true;
    }
}
