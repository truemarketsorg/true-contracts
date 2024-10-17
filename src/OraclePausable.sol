// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Inheritance
import "./interfaces/ITruthMarketManager.sol";

// Clone of syntetix contract without constructor

contract OraclePausable is OwnableUpgradeable {
    uint public lastPauseTime;
    bool public paused;

    /**
     * @notice Change the paused state of the contract
     * @dev Only the contract owner may call this.
     */
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
            ITruthMarketManager(owner()).isPauserAddress(msg.sender) ||
                ITruthMarketManager(owner()).owner() == msg.sender ||
                owner() == msg.sender,
            "Non-pauser address"
        );
        _;
    }
}