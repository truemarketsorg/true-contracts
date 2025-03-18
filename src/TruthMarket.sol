// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import "./YesNoToken.sol";
import "./OraclePausable.sol";
import "./MarketEnums.sol";
import "./BondConstants.sol";
import "./EscalationStructs.sol";
import "./interfaces/ITruthMarketManager.sol";
import "./interfaces/ITruthMarket.sol";
import "./interfaces/IOracleBonds.sol";
import "./interfaces/IOracleCouncil.sol";
import "./interfaces/IEscalation.sol";
import "./interfaces/IBlacklistable.sol";

contract TruthMarket is Initializable, OwnableUpgradeable, OraclePausable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    struct StatusChange {
        MarketStatus status;
        uint256 timestamp;
        uint256 outcome;
    }

    string public constant VERSION = "1.1.0";

    uint256 private constant _HUNDRED = 100;
    uint256 private constant _ONE_PERCENT = 1e16;
    uint256 private constant _HUNDRED_PERCENT = 1e18;

    uint256 private constant _YES = 1;
    uint256 private constant _NO = 2;
    uint256 private constant _CANCELED = 3;

    uint256 public winningPosition;

    uint256 public endOfTrading;

    uint256 public createdAt;
    uint256 public resolutionProposedAt;
    uint256 public disputedAt;
    uint256 public councilDecisionAt;
    uint256 public escalatedDisputeAt;
    uint256 public finalizedAt;

    uint256 public firstChallengePeriod;
    uint256 public secondChallengePeriod;

    uint256 public yesNoTokenCap;

    uint256 public resolverBondAmount;
    uint256 public disputerBondAmount;
    uint256 public escalatorBondAmount;

    ITruthMarketManager public marketManager;
    IOracleBonds public oracleBonds;
    IOracleCouncil public oracleCouncil;
    IEscalation public escalation;

    string public marketQuestion;
    string public marketSource;
    string public additionalInfo;

    IERC20Metadata public paymentToken;
    YesNoToken public yesToken;
    YesNoToken public noToken;
    uint256 private _paymentTokenDecimals;
    uint256 private _tokenDecimals;
    uint256 public rewardAmount;

    uint24 public constant POOL_FEE = 3000; // 0.3%

    address public yesPool;
    address public noPool;

    IERC20 public rewardToken;

    MarketStatus public currentStatus;
    StatusChange[] public statusHistory;

    bool public bondSettled;

    event BondsSettled(address market, uint256 winningPosition);
    event MarketStatusUpdated(MarketStatus from, MarketStatus to, uint256 outcome);
    event TokensMinted(address indexed user, uint256 amount);
    event TokensBurned(address indexed user, uint256 amount);
    event TokensRedeemed(address indexed user, uint256 amount);
    event WithdrawnFromCanceledMarket(address indexed user, uint256 yesAmount, uint256 noAmount, uint256 paymentAmount);
    event YesNoTokenCapChanged(uint256 yesNoTokenCap);
    event EndOfTradingChanged(uint256 endOfTrading);
    event FirstChallengePeriodChanged(uint256 firstChallengePeriod);
    event SecondChallengePeriodChanged(uint256 secondChallengePeriod);
    event RewardReceiverBlacklisted(address indexed token, address indexed account);

    error TokenCapExceeded();
    error MarketNotInTradingPhase();
    error MarketNotDisputed();
    error MarketNotFinalized();
    error MarketNotCanceled();
    error MarketFinalized();
    error InvalidOutcome(uint256 outcome);
    error InvalidStatusTransition(MarketStatus from, MarketStatus to);
    error BondsAlreadySettled();
    error NoTokensToWithdraw();
    error InvalidBondAmount();
    error InvalidChallengePeriod();
    error InvalidAddress();

    // Constructor //////////////////////////////////////////////////////

    /// @notice Initializes a new market with the specified parameters
    /// @param _marketQuestion The question that the market will resolve
    /// @param _marketSource The source that will be used to verify the outcome
    /// @param _additionalInfo Additional information about the market
    /// @param _endOfTrading The timestamp when trading will end
    /// @param _yesNoTokenCap The maximum amount of YES/NO tokens that can be minted
    /// @param _paymentToken The token used for payments
    /// @param _yesToken The YES token contract address
    /// @param _noToken The NO token contract address
    /// @param _rewardToken The token used for rewards
    /// @param _rewardAmount The amount of reward tokens
    function initialize(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _paymentToken,
        address _yesToken,
        address _noToken,
        address _rewardToken,
        uint256 _rewardAmount
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        marketManager = ITruthMarketManager(msg.sender);
        oracleBonds = IOracleBonds(marketManager.oracleBonds());
        if (address(oracleBonds) == address(0)) {
            revert InvalidAddress();
        }
        oracleCouncil = IOracleCouncil(marketManager.oracleCouncilAddress());
        if (address(oracleCouncil) == address(0)) {
            revert InvalidAddress();
        }
        escalation = IEscalation(marketManager.escalationAddress());
        if (address(escalation) == address(0)) {
            revert InvalidAddress();
        }

        _initializeWithParameters(_marketQuestion, _marketSource, _additionalInfo, _endOfTrading, _yesNoTokenCap);
        resolverBondAmount = marketManager.resolverBondAmount();
        disputerBondAmount = marketManager.disputerBondAmount();
        escalatorBondAmount = marketManager.escalatorBondAmount();
        if (resolverBondAmount == 0 || disputerBondAmount == 0 || escalatorBondAmount == 0) {
            revert InvalidBondAmount();
        }

        firstChallengePeriod = marketManager.firstChallengePeriod();
        secondChallengePeriod = marketManager.secondChallengePeriod();
        if (firstChallengePeriod == 0 || secondChallengePeriod == 0) {
            revert InvalidChallengePeriod();
        }

        paymentToken = IERC20Metadata(_paymentToken);
        yesToken = YesNoToken(_yesToken);
        noToken = YesNoToken(_noToken);

        _paymentTokenDecimals = paymentToken.decimals();
        _tokenDecimals = yesToken.decimals();

        IUniswapV3Factory uniswapV3Factory = IUniswapV3Factory(marketManager.uniswapV3Factory());

        // Check if pool exists first, if not then create
        address existingYesPool = uniswapV3Factory.getPool(_yesToken, _paymentToken, POOL_FEE);
        yesPool = existingYesPool == address(0)
            ? uniswapV3Factory.createPool(_yesToken, _paymentToken, POOL_FEE)
            : existingYesPool;

        address existingNoPool = uniswapV3Factory.getPool(_noToken, _paymentToken, POOL_FEE);
        noPool = existingNoPool == address(0)
            ? uniswapV3Factory.createPool(_noToken, _paymentToken, POOL_FEE)
            : existingNoPool;

        bondSettled = false;

        rewardToken = IERC20(_rewardToken);
        rewardAmount = _rewardAmount;

        currentStatus = MarketStatus.Created;
        statusHistory.push(StatusChange(MarketStatus.Created, block.timestamp, 0));
    }

    // External functions //////////////////////////////////////////////

    function proposeResolution(uint256 _outcome) external onlyOwner {
        if (_outcome > _CANCELED || _outcome == 0) {
            revert InvalidOutcome(_outcome);
        }
        winningPosition = _outcome;
        resolutionProposedAt = block.timestamp;

        // resolver should be punish and OpenForResolution was not set to history
        if (currentStatus == MarketStatus.ResetByCouncil) {
            disputedAt = 0;
            councilDecisionAt = 0;

            IOracleCouncil.Dispute memory lastDispute = oracleCouncil.getLastClosedDispute(address(this));
            oracleBonds.sendBondFromMarketToSafeBox(
                address(this), BondConstants.RESOLVER_BOND, lastDispute.disputorAddress
            );
            oracleBonds.issueBondsBackToDisputor(address(this), lastDispute.disputorAddress);
            marketManager.resetMarketStatus(address(this));
        }

        _updateStatus(MarketStatus.ResolutionProposed, _outcome);
    }

    function raiseDispute() external onlyOwner {
        disputedAt = block.timestamp;

        _updateStatus(MarketStatus.DisputeRaised, 0);
    }

    function resolveMarketByCouncil(uint256 _outcome) external onlyOwner {
        winningPosition = _outcome;
        councilDecisionAt = block.timestamp;

        _updateStatus(MarketStatus.SetByCouncil, _outcome);
    }

    function resetMarketByCouncil(bool _returnToOpenForResolution) external onlyOwner {
        if (_returnToOpenForResolution) {
            winningPosition = 0;
            resolutionProposedAt = 0;
            disputedAt = 0;
            councilDecisionAt = 0;
            _updateStatus(MarketStatus.OpenForResolution, 0);
            // issue bonds back to disputor and resolver since no one is punished
            oracleBonds.issueBondsBackToResolver(address(this));
            oracleBonds.issueBondsBackToDisputor(
                address(this), oracleCouncil.getLastClosedDispute(address(this)).disputorAddress
            );
            marketManager.resetMarketStatus(address(this));
        } else {
            councilDecisionAt = block.timestamp;
            _updateStatus(MarketStatus.ResetByCouncil, 0);
        }
    }

    function raiseEscalatedDispute() external onlyOwner {
        escalatedDisputeAt = block.timestamp;
        _updateStatus(MarketStatus.EscalatedDisputeRaised, 0);
    }

    function resolveMarketByEscalation(uint256 _outcome) external onlyOwner {
        if (_outcome > _CANCELED || _outcome == 0) {
            revert InvalidOutcome(_outcome);
        }

        winningPosition = _outcome;
        finalizedAt = block.timestamp;

        _updateStatus(MarketStatus.Finalized, _outcome);
    }

    function resetMarketByEscalation() external onlyOwner {
        winningPosition = 0;
        resolutionProposedAt = 0;
        disputedAt = 0;
        councilDecisionAt = 0;
        escalatedDisputeAt = 0;

        EscalatedDispute memory lastEscalation = escalation.getEscalatedDispute(address(this));
        IOracleCouncil.Dispute memory lastDispute = oracleCouncil.getLastClosedDispute(address(this));

        _handleBondsForEscalation(lastEscalation, lastDispute);

        marketManager.resetMarketStatus(address(this));

        _updateStatus(MarketStatus.OpenForResolution, 0);
    }

    function setYesNoTokenCap(uint256 _yesNoTokenCap) external onlyOwner {
        yesNoTokenCap = _yesNoTokenCap;
        emit YesNoTokenCapChanged(_yesNoTokenCap);
    }

    function setEndOfTrading(uint256 _endOfTrading) external onlyOwner {
        // check if market is in trading phase
        if (getCurrentStatus() != MarketStatus.Created) {
            revert MarketNotInTradingPhase();
        }
        endOfTrading = _endOfTrading;
        emit EndOfTradingChanged(_endOfTrading);
    }

    function setFirstChallengePeriod(uint256 _firstChallengePeriod) external onlyOwner {
        firstChallengePeriod = _firstChallengePeriod;
        emit FirstChallengePeriodChanged(_firstChallengePeriod);
    }

    function setSecondChallengePeriod(uint256 _secondChallengePeriod) external onlyOwner {
        secondChallengePeriod = _secondChallengePeriod;
        emit SecondChallengePeriodChanged(_secondChallengePeriod);
    }

    // mint is not available after market is finalized
    function mint(uint256 paymentTokenAmount) external notPaused nonReentrant {
        if (getCurrentStatus() == MarketStatus.Finalized) {
            revert MarketFinalized();
        }

        uint256 tokenAmount = paymentTokenAmount * (10 ** _tokenDecimals) / (10 ** _paymentTokenDecimals);

        // Check if total supply of both Yes and No tokens would exceed the cap
        // Since YesNoToken inherits from ERC20Burnable, users can burn Yes or No tokens independently
        // This can lead to an imbalance between Yes and No token total supplies
        // Example: When Yes = 80, No = 90, if we only check Yes tokens, users can still mint 20 more tokens
        // This would result in Yes = 100, No = 110, causing No tokens to exceed the cap
        if (yesToken.totalSupply() + tokenAmount > yesNoTokenCap || noToken.totalSupply() + tokenAmount > yesNoTokenCap) {
            revert TokenCapExceeded();
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), paymentTokenAmount);

        yesToken.mint(msg.sender, tokenAmount);
        noToken.mint(msg.sender, tokenAmount);

        emit TokensMinted(msg.sender, tokenAmount);
    }

    function burn(uint256 amount) external notPaused nonReentrant {
        if (getCurrentStatus() == MarketStatus.Finalized) {
            revert MarketFinalized();
        }
        uint256 paymentTokenAmount = amount * (10 ** _paymentTokenDecimals) / (10 ** _tokenDecimals);
        yesToken.burnFrom(msg.sender, amount);
        noToken.burnFrom(msg.sender, amount);
        paymentToken.safeTransfer(msg.sender, paymentTokenAmount);
        emit TokensBurned(msg.sender, amount);
    }

    function redeem(uint256 amount) external notPaused nonReentrant {
        if (getCurrentStatus() != MarketStatus.Finalized) {
            revert MarketNotFinalized();
        }
        if (winningPosition != _YES && winningPosition != _NO) {
            revert InvalidOutcome(winningPosition);
        }

        // set market status to finalized if not already
        if (currentStatus != MarketStatus.Finalized) {
            _setStatusToFinalized(winningPosition);
        }

        if (!bondSettled) {
            _settleBonds();
        }
        // amount is in yesToken decimals, so we need to convert to paymentToken decimals
        uint256 paymentTokenAmount = amount * (10 ** _paymentTokenDecimals) / (10 ** _tokenDecimals);

        if (winningPosition == _YES) {
            // YES won
            yesToken.burnFrom(msg.sender, amount);
        } else {
            // NO won
            noToken.burnFrom(msg.sender, amount);
        }

        paymentToken.safeTransfer(msg.sender, paymentTokenAmount);
        emit TokensRedeemed(msg.sender, amount);
    }

    function withdrawFromCanceledMarket() external notPaused nonReentrant {
        if (getCurrentStatus() != MarketStatus.Finalized) {
            revert MarketNotFinalized();
        }
        if (winningPosition != _CANCELED) {
            revert MarketNotCanceled();
        }

        // set market status to finalized if not already
        if (currentStatus != MarketStatus.Finalized) {
            _setStatusToFinalized(winningPosition);
        }

        if (!bondSettled) {
            _settleBonds();
        }

        uint256 yesBalance = yesToken.balanceOf(msg.sender);
        uint256 noBalance = noToken.balanceOf(msg.sender);
        uint256 totalBalance = yesBalance + noBalance;

        if (totalBalance == 0) {
            revert NoTokensToWithdraw();
        }

        // Calculate the withdrawal amount at 0.5 USDC per token
        uint256 paymentTokenAmount = totalBalance * (5 * 10 ** (_paymentTokenDecimals - 1)) / (10 ** _tokenDecimals);

        // Burn all YES and NO tokens
        yesToken.burnFrom(msg.sender, yesBalance);
        noToken.burnFrom(msg.sender, noBalance);

        paymentToken.safeTransfer(msg.sender, paymentTokenAmount);
        emit WithdrawnFromCanceledMarket(msg.sender, yesBalance, noBalance, paymentTokenAmount);
    }

    function settleBonds() external notPaused nonReentrant {
        _settleBonds();
    }

    // External view functions ////////////////////////////////////////

    function positionCount() external pure returns (uint256) {
        // _YES, _NO, _CANCELED
        return 3;
    }

    function getUserClaimableAmount(address _account) public view returns (uint256) {
        uint256 winningTokenBalance;
        if (winningPosition == _YES) {
            winningTokenBalance = yesToken.balanceOf(_account);
        } else if (winningPosition == _NO) {
            winningTokenBalance = noToken.balanceOf(_account);
        } else if (winningPosition == _CANCELED) {
            winningTokenBalance = (yesToken.balanceOf(_account) + noToken.balanceOf(_account)) / 2;
        } else {
            return 0; // if market is cancelled, user cannot claim through redeem(). Use withdrawFromCanceledMarket() or burn() instead.
        }

        uint256 claimableAmount = winningTokenBalance * (10 ** _paymentTokenDecimals) / (10 ** _tokenDecimals);

        return claimableAmount;
    }

    function getAllAmounts() external view returns (uint256, uint256, uint256) {
        return (resolverBondAmount, disputerBondAmount, escalatorBondAmount);
    }

    function getCurrentStatus() public view returns (MarketStatus) {
        MarketStatus currentState = currentStatus;

        if (currentState == MarketStatus.Created && block.timestamp > endOfTrading) {
            return MarketStatus.OpenForResolution;
        }

        if (
            currentState == MarketStatus.ResolutionProposed
                && block.timestamp > resolutionProposedAt + firstChallengePeriod
        ) {
            return MarketStatus.Finalized;
        }

        if (currentState == MarketStatus.SetByCouncil && block.timestamp > councilDecisionAt + secondChallengePeriod) {
            return MarketStatus.Finalized;
        }

        if (currentState == MarketStatus.ResetByCouncil && block.timestamp > councilDecisionAt + secondChallengePeriod)
        {
            return MarketStatus.OpenForResolution;
        }

        return currentState;
    }

    function getUserPosition(address user) external view returns (uint256 yesAmount, uint256 noAmount) {
        yesAmount = yesToken.balanceOf(user);
        noAmount = noToken.balanceOf(user);
    }

    function getPoolAddresses() external view returns (address, address) {
        return (yesPool, noPool);
    }

    // Public functions ////////////////////////////////////////////////

    // Internal functions //////////////////////////////////////////////

    function _updateStatus(MarketStatus _newStatus, uint256 _outcome) internal {
        MarketStatus _currentState = getCurrentStatus();
        if (!_isValidTransition(_currentState, _newStatus)) {
            revert InvalidStatusTransition(_currentState, _newStatus);
        }
        currentStatus = _newStatus;
        statusHistory.push(StatusChange(_newStatus, block.timestamp, _outcome));
        emit MarketStatusUpdated(_currentState, _newStatus, _outcome);
    }

    // This function is used when getCurrentStatus() is finalized
    // but the currentStatus is not yet set to finalized
    // e.g., when market reaches finalized via challenge period ends
    function _setStatusToFinalized(uint256 _outcome) internal {
        MarketStatus _currentStatus = currentStatus;
        currentStatus = MarketStatus.Finalized;
        finalizedAt = block.timestamp;
        emit MarketStatusUpdated(_currentStatus, MarketStatus.Finalized, _outcome);
    }

    // Private functions //////////////////////////////////////////////

    function _initializeWithParameters(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap
    ) private {
        createdAt = block.timestamp;
        marketQuestion = _marketQuestion;
        marketSource = _marketSource;
        additionalInfo = _additionalInfo;
        endOfTrading = _endOfTrading;
        yesNoTokenCap = _yesNoTokenCap;
    }

    function _transferReward(address _receiver) private notPaused {
        if (rewardAmount == 0) {
            return;
        }

        bool isBlacklisted = false;
        try IBlacklistable(address(rewardToken)).isBlacklisted(_receiver) returns (bool result) {
            isBlacklisted = result;
        } catch {
            // interface not implemented or call failed, treat as not blacklisted
            isBlacklisted = false;
        }

        if (isBlacklisted) {
            rewardToken.safeTransfer(marketManager.safeBoxAddress(), rewardAmount);
            emit RewardReceiverBlacklisted(address(rewardToken), _receiver);
        } else {
            rewardToken.safeTransfer(_receiver, rewardAmount);
        }
    }

    function _settleBonds() private {
        if (getCurrentStatus() != MarketStatus.Finalized) {
            revert MarketNotFinalized();
        }
        if (bondSettled) {
            revert BondsAlreadySettled();
        }

        if (escalatedDisputeAt > 0) {
            EscalatedDispute memory lastEscalation = escalation.getEscalatedDispute(address(this));
            IOracleCouncil.Dispute memory lastDispute = oracleCouncil.getLastClosedDispute(address(this));
            _handleBondsForEscalation(lastEscalation, lastDispute);

            if (lastEscalation.resultWinningPosition == _CANCELED) {
                _transferReward(marketManager.safeBoxAddress());
            } else if (lastEscalation.resultWinningPosition == lastDispute.originalOutcomeFromResolver) {
                _transferReward(marketManager.resolverAddress(address(this)));
            } else {
                _transferReward(lastDispute.disputorAddress);
            }
        } else if (councilDecisionAt > 0) {
            IOracleCouncil.Dispute memory lastDispute = oracleCouncil.getLastClosedDispute(address(this));

            if (lastDispute.isResolverPunished) {
                oracleBonds.sendBondFromMarketToSafeBox(
                    address(this), BondConstants.RESOLVER_BOND, lastDispute.disputorAddress
                );
            } else {
                oracleBonds.issueBondsBackToResolver(address(this));
            }

            if (lastDispute.isDisputorPunished) {
                oracleBonds.sendBondFromMarketToSafeBox(
                    address(this), BondConstants.DISPUTOR_BOND, lastDispute.disputorAddress
                );
            } else {
                oracleBonds.issueBondsBackToDisputor(address(this), lastDispute.disputorAddress);
            }

            if (lastDispute.winningPosition == _CANCELED) {
                _transferReward(marketManager.safeBoxAddress());
            } else if (lastDispute.winningPosition == lastDispute.originalOutcomeFromResolver) {
                _transferReward(marketManager.resolverAddress(address(this)));
            } else {
                _transferReward(lastDispute.disputorAddress);
            }
        } else {
            oracleBonds.issueBondsBackToResolver(address(this));
            if (winningPosition == _CANCELED) {
                _transferReward(marketManager.safeBoxAddress());
            } else {
                _transferReward(marketManager.resolverAddress(address(this)));
            }
        }

        bondSettled = true;
        emit BondsSettled(address(this), winningPosition);
    }

    function _isValidTransition(MarketStatus from, MarketStatus to) private view returns (bool) {
        if (from == MarketStatus.Created) {
            return to == MarketStatus.OpenForResolution && block.timestamp > endOfTrading;
        }

        if (from == MarketStatus.OpenForResolution) {
            return to == MarketStatus.ResolutionProposed;
        }

        if (from == MarketStatus.ResolutionProposed) {
            if (block.timestamp <= resolutionProposedAt + firstChallengePeriod) {
                return to == MarketStatus.DisputeRaised;
            } else {
                return to == MarketStatus.Finalized;
            }
        }

        if (from == MarketStatus.DisputeRaised) {
            return to == MarketStatus.SetByCouncil || to == MarketStatus.ResetByCouncil
                || to == MarketStatus.OpenForResolution;
        }

        if (from == MarketStatus.SetByCouncil) {
            if (block.timestamp <= councilDecisionAt + secondChallengePeriod) {
                return to == MarketStatus.EscalatedDisputeRaised;
            } else {
                return to == MarketStatus.Finalized;
            }
        }

        if (from == MarketStatus.ResetByCouncil) {
            if (block.timestamp <= councilDecisionAt + secondChallengePeriod) {
                return to == MarketStatus.EscalatedDisputeRaised;
            } else {
                return to == MarketStatus.OpenForResolution;
            }
        }

        if (from == MarketStatus.EscalatedDisputeRaised) {
            return to == MarketStatus.Finalized || to == MarketStatus.OpenForResolution;
        }

        return false;
    }

    function _handleBondsForEscalation(
        EscalatedDispute memory lastEscalation,
        IOracleCouncil.Dispute memory lastDispute
    ) private {
        if (lastEscalation.isOriginalResolverPunished) {
            oracleBonds.sendBondFromMarketToSafeBox(
                address(this), BondConstants.RESOLVER_BOND, lastDispute.disputorAddress
            );
        } else {
            oracleBonds.issueBondsBackToResolver(address(this));
        }

        if (lastEscalation.isCouncilDisputorPunished) {
            oracleBonds.sendBondFromMarketToSafeBox(
                address(this), BondConstants.DISPUTOR_BOND, lastDispute.disputorAddress
            );
        } else {
            oracleBonds.issueBondsBackToDisputor(address(this), lastDispute.disputorAddress);
        }

        if (lastEscalation.isEscalatedDisputorPunished) {
            oracleBonds.sendBondFromMarketToSafeBox(
                address(this), BondConstants.ESCALATED_DISPUTOR_BOND, lastEscalation.escalatedDisputorAddress
            );
        } else {
            oracleBonds.issueBondsBackToEscalatedDisputor(address(this));
        }
    }
}
