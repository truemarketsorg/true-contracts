// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITruthMarketV2} from "./interfaces/ITruthMarketV2.sol";
import {ITruthMarketManager} from "./interfaces/ITruthMarketManager.sol";
import {MarketStatus} from "./MarketEnums.sol";

contract TokenConverter is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // State ////////////////////////////////////////////////////////
    address public receiver; // Protocol wallet address
    ITruthMarketManager public marketManager; // Registry used to validate markets

    // Events ////////////////////////////////////////////////////////
    event TokensConverted(address indexed market, uint256 paymentAmount);
    event TokensWithdrawn(address indexed token, uint256 amount, address indexed to);
    event ReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event MarketManagerUpdated(address indexed oldManager, address indexed newManager);

    // Errors ////////////////////////////////////////////////////////
    error InvalidReceiver();
    error InvalidMarketManager();
    error InvalidMarket(address market);
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

    /// @notice Set the market manager used to validate markets before conversion
    /// @param newManager Address of the TruthMarketManager registry
    function setMarketManager(address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newManager == address(0)) revert InvalidMarketManager();
        address oldManager = address(marketManager);
        marketManager = ITruthMarketManager(newManager);
        emit MarketManagerUpdated(oldManager, newManager);
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
    /// @dev The market MUST be registered in the TruthMarketManager. Without this
    ///      gate any caller could pass an attacker-controlled contract that reports
    ///      a token the converter holds and have the converter approve it, allowing
    ///      the attacker to drain that balance via the subsequent external call.
    function _convertMarketTokens(address market) internal {
        if (address(marketManager) == address(0)) revert InvalidMarketManager();
        if (!marketManager.isActiveMarket(market)) revert InvalidMarket(market);

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

            if (winningPosition == 1) {
                // YES won
                if (yesBalance > 0) {
                    IERC20(yesToken).forceApprove(market, yesBalance);
                    truthMarket.redeem(yesBalance);
                    IERC20(yesToken).forceApprove(market, 0);
                    convertedAmount = yesBalance;
                }
            } else if (winningPosition == 2) {
                // NO won
                if (noBalance > 0) {
                    IERC20(noToken).forceApprove(market, noBalance);
                    truthMarket.redeem(noBalance);
                    IERC20(noToken).forceApprove(market, 0);
                    convertedAmount = noBalance;
                }
            } else if (winningPosition == 3) {
                // CANCELED
                if (yesBalance > 0) {
                    IERC20(yesToken).forceApprove(market, yesBalance);
                }
                if (noBalance > 0) {
                    IERC20(noToken).forceApprove(market, noBalance);
                }
                if (yesBalance > 0 || noBalance > 0) {
                    truthMarket.withdrawFromCanceledMarket();
                    if (yesBalance > 0) IERC20(yesToken).forceApprove(market, 0);
                    if (noBalance > 0) IERC20(noToken).forceApprove(market, 0);
                    convertedAmount = yesBalance + noBalance;
                }
            }
        } else {
            // Market not finalized, use burn logic for equal amounts
            uint256 burnAmount = yesBalance < noBalance ? yesBalance : noBalance;
            if (burnAmount > 0) {
                IERC20(yesToken).forceApprove(market, burnAmount);
                IERC20(noToken).forceApprove(market, burnAmount);
                truthMarket.burn(burnAmount);
                IERC20(yesToken).forceApprove(market, 0);
                IERC20(noToken).forceApprove(market, 0);
                convertedAmount = burnAmount;
            }
        }

        emit TokensConverted(market, convertedAmount);
    }

    /// @notice Authorize upgrade to new implementation
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
