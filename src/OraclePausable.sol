// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Inheritance
import "./interfaces/ITruthMarketManager.sol";
import "./libraries/Roles.sol";

// Clone of syntetix contract without constructor

contract OraclePausable is OwnableUpgradeable {
    uint public lastPauseTime;
    bool public paused;

    /// @notice Changes the paused state of the contract
    /// @param _paused The new paused state to set
    /// @dev Only callable by addresses with PAUSER_ROLE or the owner. Only Protocol DAO can unpause
    function setPaused(bool _paused) external pauserOnly {
        // Ensure we're actually changing the state before we do anything
        if (_paused == paused) {
            return;
        }
        if (paused) {
            require(msg.sender == ITruthMarketManager(owner()).owner(), "Only Protocol DAO can unpause");
        }
        // Set our paused state.
        paused = _paused;

        // If applicable, set the last pause time.
        if (paused) {
            lastPauseTime = block.timestamp;
        }

        // Let everyone know that our pause state has changed.
        emit PauseChanged(paused);
    }

    event PauseChanged(bool isPaused);

    modifier notPaused() {
        require(!ITruthMarketManager(owner()).paused(), "Manager paused.");
        require(!paused, "Contract is paused");
        _;
    }

    modifier pauserOnly() {
        require(
            ITruthMarketManager(owner()).hasRole(Roles.PAUSER_ROLE, msg.sender) ||
                owner() == msg.sender,
            "Non-pauser address"
        );
        _;
    }
}