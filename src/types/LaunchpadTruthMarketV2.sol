// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @notice Parameters for TruthMarketV2 deployment
struct TruthMarketV2Params {
    string question;
    string source;
    string additionalInfo;
    uint256 endOfTrading;
    address rewardToken;
    uint256 rewardAmount;
    string outcomeSymbolYes;
    string outcomeSymbolNo;
    uint24 fee;
    int24 tickSpacing;
}
