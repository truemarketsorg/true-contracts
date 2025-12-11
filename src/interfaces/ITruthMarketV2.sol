// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "../MarketEnums.sol";

interface ITruthMarketV2 {
    /* ========== VIEWS / VARIABLES ========== */

    function VERSION() external view returns (string memory);

    function winningPosition() external view returns (uint256);
    
    function positionCount() external pure returns (uint256);

    function resolverBondAmount() external view returns (uint256);

    function disputerBondAmount() external view returns (uint256);

    function escalatorBondAmount() external view returns (uint256);
    
    function firstChallengePeriod() external view returns (uint256);

    function secondChallengePeriod() external view returns (uint256);
    
    function getCurrentStatus() external view returns (MarketStatus);
    
    function paused() external view returns (bool);

    function rewardAmount() external view returns (uint256);

    function paymentToken() external view returns (address);
    
    function yesToken() external view returns (address);
    
    function noToken() external view returns (address);
    
    function bondSettled() external view returns (bool);
    
    // V4-specific functions
    function getPoolKeys() external view returns (PoolKey memory yesPoolKey, PoolKey memory noPoolKey);
    function getPoolIds() external view returns (PoolId yesPoolId, PoolId noPoolId);
    
    /* ========== MUTATIVE FUNCTIONS ========== */

    function proposeResolution(uint256 _outcome) external;

    function raiseDispute() external;

    function resolveMarketByCouncil(uint256 _outcome) external;
    
    function resetMarketByCouncil(bool _returnToOpenForResolution) external;

    function raiseEscalatedDispute() external;

    function resolveMarketByEscalation(uint256 _outcome) external;
    
    function resetMarketByEscalation() external;
    
    function setYesNoTokenCap(uint256 _yesNoTokenCap) external;

    function setEndOfTrading(uint256 _endOfTrading) external;

    function setFirstChallengePeriod(uint256 _firstChallengePeriod) external;

    function setSecondChallengePeriod(uint256 _secondChallengePeriod) external;
    
    function mint(uint256 paymentTokenAmount) external;

    function burn(uint256 amount) external;

    function redeem(uint256 amount) external;
    
    function withdrawFromCanceledMarket() external;
}