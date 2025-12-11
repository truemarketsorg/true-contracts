// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITruthMarketV2} from "./interfaces/ITruthMarketV2.sol";
import {MarketStatus} from "./MarketEnums.sol";

contract TokenConverter is 
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;
    
    // State ////////////////////////////////////////////////////////
    address public receiver; // Protocol wallet address
    
    // Events ////////////////////////////////////////////////////////
    event TokensConverted(address indexed market, uint256 paymentAmount);
    event TokensWithdrawn(address indexed token, uint256 amount, address indexed to);
    event ReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    
    // Errors ////////////////////////////////////////////////////////
    error InvalidReceiver();
    error ZeroBalance();
    
    // Constructor ////////////////////////////////////////////////////////
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    // Initializer ////////////////////////////////////////////////////////
    
    /// @notice Initializes the contract
    /// @param _receiver Initial receiver address (protocol wallet)
    function initialize(address _receiver) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        if (_receiver == address(0)) revert InvalidReceiver();
        receiver = _receiver;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    // Public functions ////////////////////////////////////////////////
    
    /// @notice Convert tokens from multiple markets
    /// @param markets Array of market addresses to convert
    function convertTokens(address[] calldata markets) external nonReentrant {
        for (uint256 i = 0; i < markets.length; i++) {
            _convertMarketTokens(markets[i]);
        }
    }
    
    /// @notice Convert tokens from a single market
    /// @param market The market address to convert tokens from
    function convertSingleMarket(address market) public nonReentrant {
        _convertMarketTokens(market);
    }
    
    // Admin functions ////////////////////////////////////////////////
    
    /// @notice Set new receiver address
    /// @param newReceiver New receiver address
    function setReceiver(address newReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newReceiver == address(0)) revert InvalidReceiver();
        address oldReceiver = receiver;
        receiver = newReceiver;
        emit ReceiverUpdated(oldReceiver, newReceiver);
    }
    
    /// @notice Withdraw specific amount of tokens to receiver
    /// @param token Token address to withdraw
    /// @param amount Amount to withdraw
    function withdrawToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        IERC20(token).safeTransfer(receiver, amount);
        emit TokensWithdrawn(token, amount, receiver);
    }
    
    /// @notice Withdraw all tokens of a specific type to receiver
    /// @param token Token address to withdraw
    function withdrawAllToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(receiver, balance);
            emit TokensWithdrawn(token, balance, receiver);
        }
    }
    
    // Internal functions //////////////////////////////////////////////
    
    /// @notice Internal function to convert tokens from a market
    /// @param market The market address
    function _convertMarketTokens(address market) internal {
        ITruthMarketV2 truthMarket = ITruthMarketV2(market);
        MarketStatus status = truthMarket.getCurrentStatus();
        
        address yesToken = truthMarket.yesToken();
        address noToken = truthMarket.noToken();
        uint256 yesBalance = IERC20(yesToken).balanceOf(address(this));
        uint256 noBalance = IERC20(noToken).balanceOf(address(this));
        
        uint256 convertedAmount = 0;
        
        if (status == MarketStatus.Finalized) {
            // Market is finalized, use redeem/withdraw logic
            uint256 winningPosition = truthMarket.winningPosition();
            
            if (winningPosition == 1) { // YES won
                if (yesBalance > 0) {
                    IERC20(yesToken).approve(market, yesBalance);
                    truthMarket.redeem(yesBalance);
                    convertedAmount = yesBalance;
                }
            } else if (winningPosition == 2) { // NO won
                if (noBalance > 0) {
                    IERC20(noToken).approve(market, noBalance);
                    truthMarket.redeem(noBalance);
                    convertedAmount = noBalance;
                }
            } else if (winningPosition == 3) { // CANCELED
                if (yesBalance > 0) {
                    IERC20(yesToken).approve(market, yesBalance);
                }
                if (noBalance > 0) {
                    IERC20(noToken).approve(market, noBalance);
                }
                if (yesBalance > 0 || noBalance > 0) {
                    truthMarket.withdrawFromCanceledMarket();
                    convertedAmount = yesBalance + noBalance;
                }
            }
        } else {
            // Market not finalized, use burn logic for equal amounts
            uint256 burnAmount = yesBalance < noBalance ? yesBalance : noBalance;
            if (burnAmount > 0) {
                IERC20(yesToken).approve(market, burnAmount);
                IERC20(noToken).approve(market, burnAmount);
                truthMarket.burn(burnAmount);
                convertedAmount = burnAmount;
            }
        }
        
        emit TokensConverted(market, convertedAmount);
    }
    
    /// @notice Authorize upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}