// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "./interfaces/ITruthMarket.sol";

/**
 * @title TruthMarketAdapter
 * @notice Adapter contract to interact with TruthMarket using ERC4626 vault tokens
 * @dev This contract handles the conversion between asset tokens and vault share tokens when interacting with TruthMarket
 * This contract is upgradeable using the UUPS pattern
 */
contract TruthMarketAdapter is 
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    
    /// @notice The asset token (e.g., USDC)
    IERC20 public assetToken;
    
    /// @notice The ERC4626 vault contract
    IERC4626 public vault;
    
    /// @notice Custom error for invalid winning position
    error InvalidWinningPosition(uint256 position);
    
    /// @notice Custom error for zero share amount received
    error ZeroSharesReceived();

    /// @notice Custom error for zero YES or NO token received
    error ZeroYESOrNoTokenReceived();
    
    /// @notice Custom error for payment token mismatch
    error PaymentTokenMismatch(address expected, address actual);
    
    /**
     * @notice Emitted when vault address is updated (assetToken is derived from vault)
     * @param assetToken New asset token address
     * @param vault New vault address
     */
    event VaultUpdated(address assetToken, address vault);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initializes the contract replacing the constructor for upgradeable contracts
     * @param _vault Address of the ERC4626 vault contract
     */
    function initialize(
        address _vault
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        vault = IERC4626(_vault);
        assetToken = IERC20(vault.asset());
    }
    
    /**
     * @notice Mints YES/NO tokens by depositing asset token into vault first to get vault share token
     * @param truthMarket Address of the TruthMarket contract
     * @param assetAmount Amount of asset token to deposit
     */
    function mint(address truthMarket, uint256 assetAmount) external nonReentrant {
        ITruthMarket market = ITruthMarket(truthMarket);
        
        // Verify that market's payment token matches our vault
        address marketPaymentToken = market.paymentToken();
        if (marketPaymentToken != address(vault)) {
            revert PaymentTokenMismatch(address(vault), marketPaymentToken);
        }
        
        // Transfer asset token from user to this contract
        assetToken.safeTransferFrom(msg.sender, address(this), assetAmount);
        
        // Approve vault to spend asset token
        assetToken.approve(address(vault), assetAmount);
        
        // Deposit asset token to vault to get vault share token
        // This step converts from assetToken to vault shares
        uint256 shareAmount = vault.deposit(assetAmount, address(this));
        
        // Approve TruthMarket to spend vault share token
        IERC20(address(vault)).approve(truthMarket, shareAmount);
        
        // Get YES/NO token addresses
        address yesToken = market.yesToken();
        address noToken = market.noToken();
        
        // Record YES/NO token balances before mint
        uint256 yesBalanceBefore = IERC20(yesToken).balanceOf(address(this));
        uint256 noBalanceBefore = IERC20(noToken).balanceOf(address(this));
        
        // Mint YES/NO tokens by calling TruthMarket.mint()
        market.mint(shareAmount);
        
        // Calculate actual YES/NO tokens received using balance delta
        uint256 yesBalanceAfter = IERC20(yesToken).balanceOf(address(this));
        uint256 noBalanceAfter = IERC20(noToken).balanceOf(address(this));
        
        uint256 yesTokensReceived = yesBalanceAfter - yesBalanceBefore;
        uint256 noTokensReceived = noBalanceAfter - noBalanceBefore;
        
        if (yesTokensReceived == 0 || noTokensReceived == 0) {
            revert ZeroYESOrNoTokenReceived();
        }
        
        // Transfer YES and NO tokens to user
        IERC20(yesToken).transfer(msg.sender, yesTokensReceived);
        IERC20(noToken).transfer(msg.sender, noTokensReceived);
    }
    
    /**
     * @notice Burns YES/NO tokens and returns asset token to user after withdrawing from vault
     * @param truthMarket Address of the TruthMarket contract
     * @param amount Amount of YES/NO tokens to burn
     */
    function burn(address truthMarket, uint256 amount) external nonReentrant {
        ITruthMarket market = ITruthMarket(truthMarket);
        
        // Verify that market's payment token matches our vault
        address marketPaymentToken = market.paymentToken();
        if (marketPaymentToken != address(vault)) {
            revert PaymentTokenMismatch(address(vault), marketPaymentToken);
        }
        
        // Get YES/NO token addresses
        address yesToken = market.yesToken();
        address noToken = market.noToken();
        
        // Transfer YES and NO tokens from user to this contract
        IERC20(yesToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(noToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Approve TruthMarket to spend YES and NO tokens
        IERC20(yesToken).approve(truthMarket, amount);
        IERC20(noToken).approve(truthMarket, amount);
        
        // Record vault share balance before burning
        uint256 vaultSharesBefore = IERC20(address(vault)).balanceOf(address(this));
        
        // Burn YES/NO tokens to get vault share token
        market.burn(amount);
        
        // Calculate actual vault shares received using balance delta
        uint256 vaultSharesAfter = IERC20(address(vault)).balanceOf(address(this));
        uint256 sharesReceived = vaultSharesAfter - vaultSharesBefore;
        
        if (sharesReceived == 0) {
            revert ZeroSharesReceived();
        }
        
        // Withdraw asset token from vault directly to user
        vault.redeem(sharesReceived, msg.sender, address(this));
    }
    
    /**
     * @notice Redeems winning tokens and returns asset token to user after withdrawing from vault
     * @param truthMarket Address of the TruthMarket contract
     * @param amount Amount of winning tokens to redeem
     */
    function redeem(address truthMarket, uint256 amount) external nonReentrant {
        ITruthMarket market = ITruthMarket(truthMarket);
        
        // Verify that market's payment token matches our vault
        address marketPaymentToken = market.paymentToken();
        if (marketPaymentToken != address(vault)) {
            revert PaymentTokenMismatch(address(vault), marketPaymentToken);
        }
        
        // Get YES/NO token addresses and check winning position
        address yesToken = market.yesToken();
        address noToken = market.noToken();
        uint256 winningPosition = market.winningPosition();
        
        // Transfer winning tokens from user to this contract
        if (winningPosition == 1) { // YES won
            IERC20(yesToken).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(yesToken).approve(truthMarket, amount);
        } else if (winningPosition == 2) { // NO won
            IERC20(noToken).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(noToken).approve(truthMarket, amount);
        } else {
            revert InvalidWinningPosition(winningPosition);
        }
        
        // Record vault share balance before redeeming
        uint256 vaultSharesBefore = IERC20(address(vault)).balanceOf(address(this));
        
        // Redeem winning tokens to get vault share token
        market.redeem(amount);
        
        // Calculate actual vault shares received using balance delta
        uint256 vaultSharesAfter = IERC20(address(vault)).balanceOf(address(this));
        uint256 sharesReceived = vaultSharesAfter - vaultSharesBefore;
        
        if (sharesReceived == 0) {
            revert ZeroSharesReceived();
        }
        
        // Withdraw asset token from vault directly to user
        vault.redeem(sharesReceived, msg.sender, address(this));
    }
    
    /**
     * @notice Withdraws from canceled market and returns asset token to user after withdrawing from vault
     * @param truthMarket Address of the TruthMarket contract
     */
    function withdrawFromCanceledMarket(address truthMarket) external nonReentrant {
        ITruthMarket market = ITruthMarket(truthMarket);
        
        // Verify that market's payment token matches our vault
        address marketPaymentToken = market.paymentToken();
        if (marketPaymentToken != address(vault)) {
            revert PaymentTokenMismatch(address(vault), marketPaymentToken);
        }
        
        // Get YES/NO token addresses
        address yesToken = market.yesToken();
        address noToken = market.noToken();
        
        // Get user's YES and NO token balances
        uint256 yesBalance = IERC20(yesToken).balanceOf(msg.sender);
        uint256 noBalance = IERC20(noToken).balanceOf(msg.sender);
        
        // Transfer all YES and NO tokens from user to this contract
        if (yesBalance > 0) {
            IERC20(yesToken).safeTransferFrom(msg.sender, address(this), yesBalance);
            IERC20(yesToken).approve(truthMarket, yesBalance);
        }
        
        if (noBalance > 0) {
            IERC20(noToken).safeTransferFrom(msg.sender, address(this), noBalance);
            IERC20(noToken).approve(truthMarket, noBalance);
        }
        
        // Record vault share balance before withdrawing
        uint256 vaultSharesBefore = IERC20(address(vault)).balanceOf(address(this));
        
        // Withdraw from canceled market to get vault share token
        market.withdrawFromCanceledMarket();
        
        // Calculate actual vault shares received using balance delta
        uint256 vaultSharesAfter = IERC20(address(vault)).balanceOf(address(this));
        uint256 sharesReceived = vaultSharesAfter - vaultSharesBefore;
        
        if (sharesReceived == 0) {
            revert ZeroSharesReceived();
        }
        
        // Withdraw asset token from vault directly to user
        vault.redeem(sharesReceived, msg.sender, address(this));
    }
    
    /**
     * @notice Rescues any tokens accidentally sent to this contract
     * @param token Address of the token to rescue
     * @param to Address to send the tokens to
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
    
    /**
     * @notice Updates the vault address and retrieves the associated asset token
     * @param _vault New address of the ERC4626 vault
     */
    function setVault(
        address _vault
    ) external onlyOwner {
        vault = IERC4626(_vault);
        assetToken = IERC20(vault.asset());

        emit VaultUpdated(vault.asset(), _vault);
    }
    
    /**
     * @notice Function that should revert when msg.sender is not authorized to upgrade the contract
     * @dev Called by the upgradeable proxy contract
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
