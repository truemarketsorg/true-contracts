// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

enum EscalationStatus {
    None, // not initiated yet
    Initialized,
    Voting,
    Resolved
}
enum EscalationResult {
    None, // no outcome yet
    Accepted, // accept dispute & set outcome (YES/NO/CANCEL) 
    Reset, // accept dispute & reset outcome
    Rejected // reject dispute
}