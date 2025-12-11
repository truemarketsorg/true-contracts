// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Roles} from "./libraries/Roles.sol";

contract FeeCollector is SafeCallback, AccessControl, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // State ////////////////////////////////////////////////////////
    
    address public defaultRecipient; // Default recipient for fees (when no recipients configured or for remainder)
    address public hookAddress;
    
    // Fee recipient info struct
    struct FeeRecipient {
        address recipient;
        uint256 feeRate; // Basis points: 1 = 0.01%, 10000 = 100%
        string role; // Role description (e.g., "creator", "liquidity_provider", "protocol")
    }
    
    // Pool-specific fee tracking
    mapping(PoolId => mapping(Currency => uint256)) public poolFeeAccumulated;
    
    // Multiple recipients per pool
    mapping(PoolId => FeeRecipient[]) public poolRecipients;
    
    // Constants
    uint256 public constant FEE_DENOMINATOR = 10000; // 100% = 10000
    
    // Configurable maximum recipients per pool
    uint256 public maxRecipientsPerPool = 10; // Default to 10, configurable

    // Errors ////////////////////////////////////////////////////////
    
    error InvalidRecipient();
    error OnlyHook();
    error InvalidFeeRate();
    error ArrayLengthMismatch();
    error InvalidAmount();

    // Events ////////////////////////////////////////////////////////
    
    event FeesWithdrawn(Currency indexed currency, uint256 amount, address indexed recipient);
    event DefaultRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event MaxRecipientsUpdated(uint256 newMax);
    event PoolFeeTracked(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event RecipientSet(PoolId indexed poolId, address indexed recipient, uint256 feeRate, uint256 index);
    event RecipientsCleared(PoolId indexed poolId);
    event FeeDistributed(PoolId indexed poolId, Currency indexed currency, address indexed recipient, uint256 amount, string role);
    event HookAddressUpdated(address indexed oldHook, address indexed newHook);

    // Constructor ////////////////////////////////////////////////////////

    constructor(IPoolManager _poolManager, address _defaultRecipient) SafeCallback(_poolManager) {
        if (_defaultRecipient == address(0)) revert InvalidRecipient();
        
        defaultRecipient = _defaultRecipient;
        // hookAddress will be set later via setHookAddress()
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // External functions //////////////////////////////////////////////

    /// @notice Track fees accumulated for a specific pool (called by hook)
    /// @param poolId The pool that generated the fees
    /// @param currency The currency of the fees
    /// @param amount The amount of fees to track
    function trackPoolFee(PoolId poolId, Currency currency, uint256 amount) external {
        if (msg.sender != hookAddress) revert OnlyHook();
        
        poolFeeAccumulated[poolId][currency] += amount;
        emit PoolFeeTracked(poolId, currency, amount);
    }

    /// @notice Withdraw all accumulated fees for pools (supports single or multiple)
    /// @param poolKeys Array of pool keys to withdraw fees for
    function withdrawPoolFees(PoolKey[] calldata poolKeys) external nonReentrant {
        bytes memory data = abi.encode(poolKeys);
        poolManager.unlock(data);
    }

    // External view functions ////////////////////////////////////////

    /// @notice Get accumulated fees for a specific pool and currency
    /// @param poolKey The pool key
    /// @param currency The currency
    /// @return The accumulated fee amount
    function getPoolAccumulatedFees(PoolKey calldata poolKey, Currency currency) 
        external view returns (uint256) {
        return poolFeeAccumulated[poolKey.toId()][currency];
    }

    /// @notice Get accumulated fees for both currencies in a pool
    /// @param poolKey The pool key  
    /// @return amount0 Amount of currency0 fees
    /// @return amount1 Amount of currency1 fees
    function getPoolAccumulatedFeesBoth(PoolKey calldata poolKey) 
        external view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = poolKey.toId();
        amount0 = poolFeeAccumulated[poolId][poolKey.currency0];
        amount1 = poolFeeAccumulated[poolId][poolKey.currency1];
    }

    /// @notice Get recipients info for a pool
    /// @param poolKey The pool key
    /// @return recipients Array of FeeRecipient structs
    function getPoolRecipients(PoolKey calldata poolKey) 
        external view returns (FeeRecipient[] memory recipients) {
        recipients = poolRecipients[poolKey.toId()];
    }
    
    /// @notice Get the current maximum recipients per pool setting
    /// @return The maximum number of recipients allowed per pool
    function getMaxRecipientsPerPool() external view returns (uint256) {
        return maxRecipientsPerPool;
    }

    // Admin functions ////////////////////////////////////////////////

    /// @notice Set maximum number of recipients allowed per pool
    /// @param newMax The new maximum number of recipients
    function setMaxRecipientsPerPool(uint256 newMax) 
        external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax == 0) revert InvalidAmount();
        maxRecipientsPerPool = newMax;
        emit MaxRecipientsUpdated(newMax);
    }
    
    /// @notice Set multiple recipients and their fee rates for pools
    /// @param poolKeys Array of pool keys to set recipients for
    /// @param recipientsArray Array of FeeRecipient arrays for each pool
    function setRecipients(
        PoolKey[] calldata poolKeys,
        FeeRecipient[][] calldata recipientsArray
    ) external onlyRole(Roles.RECIPIENTS_MANAGER_ROLE) {
        if (poolKeys.length != recipientsArray.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < poolKeys.length; i++) {
            _setPoolRecipients(poolKeys[i], recipientsArray[i]);
        }
    }
    
    /// @notice Set recipients for a single pool
    /// @param poolKey The pool key
    /// @param recipients Array of FeeRecipient structs
    function setSinglePoolRecipients(
        PoolKey calldata poolKey,
        FeeRecipient[] calldata recipients
    ) external onlyRole(Roles.RECIPIENTS_MANAGER_ROLE) {
        _setPoolRecipients(poolKey, recipients);
    }
    
    /// @notice Internal function to set recipients for a pool
    function _setPoolRecipients(
        PoolKey calldata poolKey,
        FeeRecipient[] calldata recipients
    ) internal {
        if (recipients.length > maxRecipientsPerPool) revert InvalidAmount();
        
        // Validate total rate doesn't exceed 100%
        uint256 totalRate = 0;
        for (uint256 j = 0; j < recipients.length; j++) {
            if (recipients[j].recipient == address(0)) revert InvalidRecipient();
            totalRate += recipients[j].feeRate;
        }
        if (totalRate > FEE_DENOMINATOR) revert InvalidFeeRate();
        
        PoolId poolId = poolKey.toId();
        
        // Clear existing recipients
        delete poolRecipients[poolId];
        emit RecipientsCleared(poolId);
        
        // Set new recipients
        for (uint256 j = 0; j < recipients.length; j++) {
            poolRecipients[poolId].push(recipients[j]);
            emit RecipientSet(poolId, recipients[j].recipient, recipients[j].feeRate, j);
        }
    }

    /// @notice Set the hook address (only callable by admin)
    /// @param newHookAddress The hook contract address
    function setHookAddress(address newHookAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldHook = hookAddress;
        hookAddress = newHookAddress;
        emit HookAddressUpdated(oldHook, newHookAddress);
    }

    /// @notice Set the default recipient address
    /// @param newRecipient The new default recipient address
    function setDefaultRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidRecipient();
        address oldRecipient = defaultRecipient;
        defaultRecipient = newRecipient;
        emit DefaultRecipientUpdated(oldRecipient, newRecipient);
    }

    // Internal functions (SafeCallback implementation) ///////////////

    /// @notice SafeCallback implementation for handling unlock callbacks
    /// @param data Encoded withdrawal data (pool keys)
    /// @return Empty bytes (no return data needed)
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        PoolKey[] memory poolKeys = abi.decode(data, (PoolKey[]));
        
        // Handle pool-based withdrawal
        for (uint256 i = 0; i < poolKeys.length; i++) {
            PoolId poolId = poolKeys[i].toId();
            
            // Withdraw both currencies for each pool
            Currency currency0 = poolKeys[i].currency0;
            Currency currency1 = poolKeys[i].currency1;
            
            uint256 amount0 = poolFeeAccumulated[poolId][currency0];
            uint256 amount1 = poolFeeAccumulated[poolId][currency1];
            
            if (amount0 > 0) {
                _withdrawPoolFees(poolId, currency0, amount0);
                poolFeeAccumulated[poolId][currency0] = 0; // Clear after withdrawal
            }
            if (amount1 > 0) {
                _withdrawPoolFees(poolId, currency1, amount1);
                poolFeeAccumulated[poolId][currency1] = 0; // Clear after withdrawal
            }
        }
        
        return "";
    }


    /// @notice Internal function to withdraw pool fees with multi-recipient distribution
    /// @param poolId The pool ID
    /// @param currency The currency to withdraw
    /// @param amount The total amount to withdraw
    function _withdrawPoolFees(PoolId poolId, Currency currency, uint256 amount) internal {
        FeeRecipient[] memory recipients = poolRecipients[poolId];
        
        // Burn ERC6909 tokens from this contract
        poolManager.burn(address(this), currency.toId(), amount);
        
        uint256 totalDistributed = 0;
        
        // Distribute to each recipient based on their fee rate
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 recipientAmount = Math.mulDiv(amount, recipients[i].feeRate, FEE_DENOMINATOR);
            if (recipientAmount > 0) {
                poolManager.take(currency, recipients[i].recipient, recipientAmount);
                totalDistributed += recipientAmount;
                emit FeeDistributed(poolId, currency, recipients[i].recipient, recipientAmount, recipients[i].role);
            }
        }
        
        // Send remaining amount to default recipient (handles rounding dust or full amount if no recipients)
        uint256 remainingAmount = amount - totalDistributed;
        if (remainingAmount > 0) {
            poolManager.take(currency, defaultRecipient, remainingAmount);
            emit FeeDistributed(poolId, currency, defaultRecipient, remainingAmount, "default_recipient");
        }
        
        emit FeesWithdrawn(currency, amount, defaultRecipient); // For compatibility
    }
}