// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

enum MarketStatus {
    Created,                // 0
    OpenForResolution,      // 1
    ResolutionProposed,     // 2
    DisputeRaised,          // 3
    SetByCouncil,           // 4
    ResetByCouncil,         // 5
    EscalatedDisputeRaised, // 6
    Finalized               // 7
}