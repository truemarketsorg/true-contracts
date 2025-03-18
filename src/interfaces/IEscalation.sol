// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../EscalationEnums.sol";
import "../EscalationStructs.sol";

interface IEscalation {
    /* ========== VIEWS / VARIABLES ========== */
    function isEscalationOpen(address _market) external view returns (bool);

    function getEscalatedDispute(address _market) external view returns (EscalatedDispute memory);

    /* ========== MUTATIVE FUNCTIONS ========== */
    function resetEscalationStatus(address _market) external;
}