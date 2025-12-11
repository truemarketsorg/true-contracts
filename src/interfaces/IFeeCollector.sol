// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IFeeCollector {
    // Fee recipient info struct
    struct FeeRecipient {
        address recipient;
        uint256 feeRate; // Basis points: 1 = 0.01%, 10000 = 100%
    }

    // Pool-specific functions
    function trackPoolFee(PoolId poolId, Currency currency, uint256 amount) external;
    function withdrawPoolFees(PoolKey[] calldata poolKeys) external;
    function getPoolAccumulatedFees(PoolKey calldata poolKey, Currency currency) external view returns (uint256);
    function getPoolAccumulatedFeesBoth(PoolKey calldata poolKey) external view returns (uint256 amount0, uint256 amount1);
    function getPoolRecipients(PoolKey calldata poolKey) external view returns (FeeRecipient[] memory recipients);
    function getMaxRecipientsPerPool() external view returns (uint256);

    // Recipients management
    function setRecipients(PoolKey[] calldata poolKeys, FeeRecipient[][] calldata recipientsArray) external;
    function setSinglePoolRecipients(PoolKey calldata poolKey, FeeRecipient[] calldata recipients) external;
    function setMaxRecipientsPerPool(uint256 newMax) external;
    function setDefaultRecipient(address newRecipient) external;
}