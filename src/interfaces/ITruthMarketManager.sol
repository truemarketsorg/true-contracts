// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ITruthMarketManager {
    /* ========== VIEWS / VARIABLES ========== */
    function paused() external view returns (bool);

    function getActiveMarketAddress(uint256 _index) external view returns (address);

    function isActiveMarket(address _marketAddress) external view returns (bool);

    function numberOfActiveMarkets() external view returns (uint256);

    function resolverBondAmount() external view returns (uint256);

    function disputerBondAmount() external view returns (uint256);

    function escalatorBondAmount() external view returns (uint256);

    function paymentToken() external view returns (address);

    function owner() external view returns (address);

    function oracleBonds() external view returns (address);

    function oracleCouncilAddress() external view returns (address);

    function escalationAddress() external view returns (address);

    function safeBoxAddress() external view returns (address);

    function uniswapV3Factory() external view returns (address);

    function creatorAddress(address _market) external view returns (address);

    function resolverAddress(address _market) external view returns (address);

    function isPauserAddress(address _pauserAddress) external view returns (bool);

    function safeBoxPercentage() external view returns (uint256);

    function creatorPercentage() external view returns (uint256);

    function resolverPercentage() external view returns (uint256);

    function firstChallengePeriod() external view returns (uint256);

    function secondChallengePeriod() external view returns (uint256);

    function maxOracleCouncilMembers() external view returns (uint256);

    function yesNoTokenCap() external view returns (uint256);

    function hasRole(bytes32 role, address account) external view returns (bool);

    /* ========== MUTATIVE FUNCTIONS ========== */

    function disputeMarket(address _marketAddress, address disputor) external;

    function escalateDisputeMarket(address _marketAddress, address disputor) external;

    function proposeResolution(address _marketAddress, uint256 _outcomePosition) external;
    function resolveMarketByCouncil(address _marketAddress, uint256 _outcomePosition) external;
    function resolveMarketByEscalation(address _marketAddress, uint256 _outcomePosition) external;

    function resetMarket(address _marketAddress) external;
    function resetMarketByCouncil(address _marketAddress, bool _returnToOpenForResolution) external;
    function resetMarketByEscalation(address _marketAddress) external;

    function setFirstChallengePeriod(address _market, uint256 _firstChallengePeriod) external;

    function setSecondChallengePeriod(address _market, uint256 _secondChallengePeriod) external;

    function setYesNoTokenCap(address _market, uint256 _yesNoTokenCap) external;

    function sendMarketBondAmountTo(address _market, address _recepient, uint256 _amount) external;

    /* ========== OWNER FUNCTIONS ========== */

    function setAddresses(
        address _truthMarketMastercopy,
        address _oracleCouncil,
        address _paymentToken,
        address _safeBox,
        address _uniswapV3Factory,
        address _rewardWallet,
        address _escalation
    ) external;

    function setPercentages(uint256 _safeBoxPercentage, uint256 _creatorPercentage, uint256 _resolverPercentage)
        external;

    function setDurations(
        uint256 _firstChallengePeriod,
        uint256 _secondChallengePeriod,
        uint256 _minimumTradingDuration
    ) external;

    function setLimits(uint256 _maxOracleCouncilMembers) external;

    function setAmounts(
        uint256 _resolverBondAmount,
        uint256 _disputerBondAmount,
        uint256 _escalatorBondAmount,
        uint256 _yesNoTokenCap
    ) external;

    function setOracleBonds(address _oracleBonds) external;

    function createMarket(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint _endOfTrading,
        uint _yesNoTokenCap,
        address _rewardToken,
        uint _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol
    ) external;

    function createMarket(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint _endOfTrading,
        uint _yesNoTokenCap,
        address _rewardToken,
        uint _rewardAmount
    ) external;

    function setEndOfTrading(address _market, uint256 _endOfTrading) external;

    function resetMarketStatus(address _market) external;
}
