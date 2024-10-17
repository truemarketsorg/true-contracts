// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOracleBonds {
    /* ========== VIEWS / VARIABLES ========== */
    function getTotalDepositedBondAmountForMarket(address _market) external view returns (uint);

    function getClaimedBondAmountForMarket(address _market) external view returns (uint);

    function getClaimableBondAmountForMarket(address _market) external view returns (uint);

    function getDisputorBondForMarket(address _market, address _disputorAddress) external view returns (uint);

    function getResolverBondForMarket(address _market) external view returns (uint);

    function getEscalatedDisputorBondForMarket(address _market) external view returns (uint);

    function sendResolverBondToMarket(
        address _market,
        address _resolverAddress,
        uint _amount
    ) external;

    function sendDisputorBondToMarket(
        address _market,
        address _disputorAddress,
        uint _amount
    ) external;

    function sendEscalatedDisputorBondToMarket(
        address _market,
        address _escalatedDisputorAddress,
        uint _amount
    ) external;

    function sendOpenDisputeBondFromMarketToDisputor(
        address _market,
        address _disputorAddress
    ) external;

    function sendBondFromMarketToSafeBox(
        address _market,
        uint _bondToReduce,
        address _disputorAddress
    ) external;

    function setManagerAddress(address _managerAddress) external;

    function issueBondsBackToResolver(address _market) external;

    function issueBondsBackToEscalatedDisputor(address _market) external;

    function issueBondsBackToDisputor(address _market, address _disputorAddress) external;
}

