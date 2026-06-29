// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/IPermit2.sol";

import "./base/LaunchpadState.sol";
import "./base/LaunchpadViewer.sol";
import "./interfaces/ILaunchpad.sol";
import "./interfaces/ILauncher.sol";
import "./interfaces/IDistributor.sol";
import "./interfaces/IPlugin.sol";
import "./libraries/Roles.sol";
import "./libraries/ModuleNames.sol";
import "./types/LaunchpadProposal.sol";
import "./types/LaunchpadHook.sol";

contract Launchpad is
    ILaunchpad,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    LaunchpadState,
    LaunchpadViewer
{
    using SafeERC20 for IERC20;
    using ProposalLibrary for Proposal;
    using ProposalDepositStateLibrary for ProposalDepositState;

    uint256 public constant FEE_SCALE = 10_000;

    uint256 public constant MAX_DISTRIBUTION_ATTEMPTS = 3;

    /// @notice Maximum number of hook bindings per proposal
    uint256 public constant MAX_HOOK_BINDINGS = 16;

    /// @notice Maximum byte length for hook binding args
    uint256 public constant MAX_HOOK_ARGS_LENGTH = 4160;

    uint256 public protocolFee;

    address public override(ILaunchpad, LaunchpadViewer) paymentToken;

    address public feeReceiver;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ISignatureTransfer internal immutable permit2;

    uint256 private _nextProposalId;

    mapping(bytes32 => address) internal _moduleRegistry;

    mapping(address => bool) private _userBlacklist;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address permit2_) {
        permit2 = ISignatureTransfer(permit2_);
        _disableInitializers();
    }

    function initialize(address paymentToken_, address feeReceiver_, uint256 protocolFee_) external initializer {
        if (address(paymentToken_) == address(0) || feeReceiver_ == address(0) || protocolFee_ > FEE_SCALE) {
            revert InvalidArguments();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();

        paymentToken = paymentToken_;
        feeReceiver = feeReceiver_;
        protocolFee = protocolFee_;
        _nextProposalId = 1;

        _grantRole(Roles.DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setProtocolFee(uint256 newFee) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (newFee > FEE_SCALE) {
            revert InvalidArguments();
        }
        uint256 oldFee = protocolFee;
        protocolFee = newFee;
        emit ProtocolFeeUpdated(oldFee, newFee);
    }

    function setFeeReceiver(address newReceiver) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (newReceiver == address(0)) {
            revert InvalidArguments();
        }
        address previous = feeReceiver;
        feeReceiver = newReceiver;
        emit FeeReceiverUpdated(previous, newReceiver);
    }

    function setModule(bytes32 name, address module) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (name == bytes32(0)) {
            revert InvalidArguments();
        }
        address oldModule = _moduleRegistry[name];
        _moduleRegistry[name] = module;
        emit ModuleUpdated(name, oldModule, module);
    }

    function resolveModule(bytes32 name) public view returns (address) {
        return _moduleRegistry[name];
    }

    function isUserBlacklisted(address user) public view returns (bool isBlacklisted) {
        isBlacklisted = _userBlacklist[user];
    }

    function setUserBlacklist(address user, bool blacklisted) external onlyRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) {
            revert InvalidArguments();
        }
        _userBlacklist[user] = blacklisted;
        emit UserBlacklistUpdated(user, blacklisted);
    }

    function propose(Proposal calldata proposal)
        external
        onlyRole(Roles.LAUNCHPAD_PROPOSER_ROLE)
        returns (uint256 proposalId)
    {
        if (isUserBlacklisted(proposal.creator)) {
            revert Blacklisted(proposal.creator);
        }

        if (proposal.endTime <= block.timestamp) {
            revert InvalidArguments();
        }

        if (_moduleRegistry[proposal.launcherRef] == address(0)) {
            revert ModuleNotRegistered(proposal.launcherRef);
        }

        if (_moduleRegistry[proposal.distributorRef] == address(0)) {
            revert ModuleNotRegistered(proposal.distributorRef);
        }

        uint256 bindingsLength = proposal.hookBindings.length;

        // Check hook bindings count
        if (bindingsLength > MAX_HOOK_BINDINGS) {
            revert TooManyHookBindings(bindingsLength, MAX_HOOK_BINDINGS);
        }

        uint256 countOfCheckProposalHooks = 0;
        bool hasOutcomeRestriction = false;
        if (bindingsLength > 0) {
            for (uint256 i; i < bindingsLength; i++) {
                HookBinding calldata binding = proposal.hookBindings[i];

                // Check args length
                if (binding.args.length > MAX_HOOK_ARGS_LENGTH) {
                    revert HookArgsTooLarge(i, binding.args.length, MAX_HOOK_ARGS_LENGTH);
                }

                address plugin = _moduleRegistry[binding.pluginRef];
                if (plugin == address(0)) {
                    revert ModuleNotRegistered(binding.pluginRef);
                }

                // Let plugin validate its args
                IPlugin(plugin).checkParameters(binding.args);

                if (binding.hookType == HookType.CheckProposal) {
                    countOfCheckProposalHooks++;
                }
                // Track whether outcome restriction is configured as a BeforeDeposit hook.
                // This ensures depositors cannot submit funds to unsupported outcome values
                // that would be ignored by downstream launcher/distributor logic.
                if (
                    binding.hookType == HookType.BeforeDeposit && binding.pluginRef == ModuleNames.PLUGIN_BINARY_OUTCOME
                ) {
                    hasOutcomeRestriction = true;
                }
            }
        }

        // at least one check proposal hook is required
        if (countOfCheckProposalHooks == 0) {
            revert InvalidArguments();
        }

        // Outcome restriction plugin is required to prevent deposits to unsupported outcomes.
        // Currently all launchers/distributors only support binary outcomes (1 = YES, 2 = NO).
        // When multi-outcome support is added, update the plugin whitelist accordingly.
        if (!hasOutcomeRestriction) {
            revert MissingOutcomeRestriction();
        }

        proposalId = _nextProposalId++;

        ProposalState storage state = _proposals[proposalId];
        state.proposal = proposal;
        state.phase = ProposalPhase.Live;

        emit ProposalCreated(proposalId);
    }

    function deposit(
        uint256 proposalId,
        uint256 outcome,
        uint256 amount,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        if (amount == 0) {
            revert InvalidArguments();
        }

        if (isUserBlacklisted(msg.sender)) {
            revert Blacklisted(msg.sender);
        }

        // Validate permit parameters
        if (permit.permitted.token != paymentToken) {
            revert InvalidArguments();
        }
        if (permit.permitted.amount < amount) {
            revert InvalidArguments();
        }

        ProposalState storage state = _proposals[proposalId];

        ProposalPhase phase = _proposalPhase(proposalId);

        _handlePhaseTransition(state, phase, proposalId);

        if (phase != ProposalPhase.Live) {
            revert ProposalHasEnded();
        }

        IPlugin.DepositInfo memory info = IPlugin.DepositInfo(proposalId, msg.sender, outcome, amount);
        state.proposal.runBeforeDepositHooks(info, _moduleRegistry);

        ProposalDepositState storage depositState = state.depositState;

        depositState.addOutcome(outcome);

        // Track active outcome count for depositor removal safety
        if (depositState.deposits[msg.sender][outcome] == 0) {
            depositState.activeOutcomeCount[msg.sender]++;
        }

        depositState.addDepositor(msg.sender);

        depositState.deposits[msg.sender][outcome] += amount;
        depositState.outcomeDeposits[outcome] += amount;
        depositState.totalDeposits += amount;

        // Transfer tokens using Permit2 signature
        permit2.permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            msg.sender,
            signature
        );

        emit DepositToProposal(msg.sender, proposalId, outcome, amount);

        _attemptLaunch(proposalId, state);
    }

    /// @notice Withdraws tokens from a proposal during Live or Failed phase
    /// @dev During Live phase, BeforeWithdraw hooks are executed and fees are charged.
    ///      During Failed phase, hooks are skipped and no fees are charged (L-01 fix).
    /// @param proposalId The ID of the proposal to withdraw from
    /// @param outcome The outcome to withdraw from
    /// @param amount The amount to withdraw (clamped to available balance)
    function withdraw(uint256 proposalId, uint256 outcome, uint256 amount) external nonReentrant {
        ProposalState storage state = _proposals[proposalId];

        ProposalPhase phase = _proposalPhase(proposalId);

        _handlePhaseTransition(state, phase, proposalId);

        if (phase != ProposalPhase.Live && phase != ProposalPhase.Failed) {
            revert ProposalHasEnded();
        }

        ProposalDepositState storage depositState = state.depositState;
        uint256 balance = depositState.deposits[msg.sender][outcome];

        if (balance < amount) {
            amount = balance;
        }

        // L-02: Reject zero-amount withdrawals after clamping to prevent state mutation without effect
        if (amount == 0) {
            revert InvalidArguments();
        }

        IPlugin.WithdrawInfo memory info =
            IPlugin.WithdrawInfo(proposalId, msg.sender, outcome, amount, balance - amount);
        // L-01: Skip hooks in Failed phase to prevent malicious hooks from blocking refunds
        if (phase == ProposalPhase.Live) {
            state.proposal.runBeforeWithdrawHooks(info, _moduleRegistry);
        }

        depositState.deposits[msg.sender][outcome] = balance - amount;
        depositState.outcomeDeposits[outcome] -= amount;
        depositState.totalDeposits -= amount;

        if (depositState.outcomeDeposits[outcome] == 0) {
            depositState.removeOutcome(outcome);
        }

        // If the balance will be zero for this outcome, decrement active outcome count
        if (balance == amount) {
            depositState.activeOutcomeCount[msg.sender]--;
            // Only remove depositor when all outcome balances are zero
            if (depositState.activeOutcomeCount[msg.sender] == 0) {
                depositState.removeDepositor(msg.sender);
            }
        }

        uint256 payout = amount;
        uint256 feeAmount;

        // only take protocol fee for live proposal withdrawals
        if (phase == ProposalPhase.Live) {
            (payout, feeAmount) = _calculateAmountAndFee(amount);
        }

        IERC20(paymentToken).safeTransfer(msg.sender, payout);

        if (feeAmount > 0) {
            IERC20(paymentToken).safeTransfer(feeReceiver, feeAmount);
        }

        emit WithdrawFromProposal(msg.sender, proposalId, outcome, amount);

        _attemptLaunch(proposalId, state);
    }

    function _handlePhaseTransition(ProposalState storage state, ProposalPhase newPhase, uint256 proposalId) private {
        if (state.phase == newPhase) {
            return;
        }

        if (newPhase == ProposalPhase.Failed) {
            emit ProposalFailed(proposalId);
        }

        state.phase = newPhase;
    }

    function _attemptLaunch(uint256 proposalId, ProposalState storage state) private {
        ProposalPhase phase = _proposalPhase(proposalId);
        _handlePhaseTransition(state, phase, proposalId);

        if (state.phase != ProposalPhase.Live) {
            return;
        }

        bool ready = state.proposal.runCheckProposalHooks(ILaunchpadViewer(address(this)), proposalId, _moduleRegistry);

        if (!ready) {
            return;
        }

        address launcherAddr = _moduleRegistry[state.proposal.launcherRef];
        if (launcherAddr == address(0)) {
            revert ModuleNotRegistered(state.proposal.launcherRef);
        }

        try ILauncher(launcherAddr).launch(ILaunchpadViewer(address(this)), proposalId, state.proposal.params) returns (
            address market
        ) {
            state.phase = ProposalPhase.Launched;
            state.market = market;

            emit ProposalLaunched(proposalId, market);

            _distribute(proposalId, state);
        } catch {
            emit LaunchAttemptFailed(proposalId);
        }
    }

    /// @dev Distributes the proposal funds to the distributor.
    /// @param proposalId The ID of the proposal to distribute.
    /// @param state The state of the proposal.
    function _distribute(uint256 proposalId, ProposalState storage state) private {
        uint256 totalDeposits = state.depositState.totalDeposits;

        address distributor = _moduleRegistry[state.proposal.distributorRef];

        (uint256 distributable, uint256 feeAmount) = _calculateAmountAndFee(totalDeposits);

        // Distribution is irreversible; on retry, skip to fee/finalize steps
        if (!state.distributed) {
            if (distributor == address(0)) {
                _handleDistributionFailure(proposalId, state);
                return;
            }
            if (distributable > 0) {
                IERC20(paymentToken).forceApprove(distributor, distributable);
            }

            try IDistributor(distributor).distribute(ILaunchpadViewer(address(this)), proposalId, distributable) {
                state.distributed = true;
            } catch (bytes memory) {
                _handleDistributionFailure(proposalId, state);
                if (distributable > 0) {
                    IERC20(paymentToken).forceApprove(distributor, 0);
                }
                return;
            }

            if (distributable > 0) {
                IERC20(paymentToken).forceApprove(distributor, 0);
            }
        }

        if (feeAmount > 0 && !state.feePaid) {
            if (_tryTransfer(paymentToken, feeReceiver, feeAmount)) {
                state.feePaid = true;
            } else {
                _handleDistributionFailure(proposalId, state);
                return;
            }
        }

        try ILauncher(_moduleRegistry[state.proposal.launcherRef]).finalize(state.market) {
            state.phase = ProposalPhase.Distributed;
            emit ProposalDistributed(proposalId);
        } catch (bytes memory) {
            _handleDistributionFailure(proposalId, state);
        }
    }

    /// @dev Handles a failed distribution attempt by incrementing the failure counter
    /// and transitioning to ManualDistributionNeeded if max attempts are exhausted.
    function _handleDistributionFailure(uint256 proposalId, ProposalState storage state) private {
        uint256 attempts = state.failedDistributionAttempts + 1;
        state.failedDistributionAttempts = attempts;

        if (attempts >= MAX_DISTRIBUTION_ATTEMPTS) {
            state.phase = ProposalPhase.ManualDistributionNeeded;
            emit ManualDistributionNeeded(proposalId);
        } else {
            emit DistributionDeferred(proposalId, attempts);
        }
    }

    /// @dev Low-level transfer that handles non-standard ERC20s (e.g. USDT that returns no bool).
    /// Mirrors SafeERC20 logic but returns success instead of reverting, so callers can defer on failure.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (data.length == 0 || abi.decode(data, (bool)));
    }

    function resolveDeferredDistribution(uint256 proposalId)
        external
        onlyRole(Roles.LAUNCHPAD_RESOLVER_ROLE)
        nonReentrant
    {
        ProposalState storage state = _proposals[proposalId];

        if (state.phase != ProposalPhase.Launched) {
            revert InvalidPhase(ProposalPhase.Launched, state.phase);
        }

        _distribute(proposalId, state);
    }

    /// @notice Retries launching a proposal that previously failed to launch
    /// @dev Permissionless — launch is already triggered by any deposit/withdraw.
    ///      This function provides a way to retry without requiring a deposit or withdrawal.
    /// @param proposalId The ID of the proposal to retry launching
    function resolveDeferredLaunch(uint256 proposalId) external nonReentrant {
        ProposalState storage state = _proposals[proposalId];

        ProposalPhase phase = _proposalPhase(proposalId);
        _handlePhaseTransition(state, phase, proposalId);

        if (phase != ProposalPhase.Live) {
            revert InvalidPhase(ProposalPhase.Live, phase);
        }

        _attemptLaunch(proposalId, state);
    }

    function withdrawFunds(uint256 proposalId, address receiver)
        external
        onlyRole(Roles.LAUNCHPAD_RESOLVER_ROLE)
        nonReentrant
    {
        if (receiver == address(0)) {
            revert InvalidArguments();
        }

        ProposalState storage state = _proposals[proposalId];

        if (state.phase != ProposalPhase.ManualDistributionNeeded) {
            revert InvalidPhase(ProposalPhase.ManualDistributionNeeded, state.phase);
        }

        uint256 totalDeposits = state.depositState.totalDeposits;
        (uint256 distributable, uint256 feeAmount) = _calculateAmountAndFee(totalDeposits);

        if (feeAmount > 0 && !state.feePaid) {
            IERC20(paymentToken).safeTransfer(feeReceiver, feeAmount);
        }

        if (distributable > 0 && !state.distributed) {
            IERC20(paymentToken).safeTransfer(receiver, distributable);
        }

        state.phase = ProposalPhase.FundsWithdrawn;
        emit FundsWithdrawn(proposalId, receiver);
    }

    /// @notice Completes manual distribution by finalizing the market (unpausing pools)
    /// @dev Called after ops team has manually distributed funds off-chain.
    ///      This function transitions the proposal from FundsWithdrawn to Distributed phase
    ///      and calls finalize() on the launcher to unpause the market pools.
    /// @param proposalId The ID of the proposal in FundsWithdrawn phase
    function completeManualDistribution(uint256 proposalId)
        external
        onlyRole(Roles.LAUNCHPAD_RESOLVER_ROLE)
        nonReentrant
    {
        ProposalState storage state = _proposals[proposalId];

        if (state.phase != ProposalPhase.FundsWithdrawn) {
            revert InvalidPhase(ProposalPhase.FundsWithdrawn, state.phase);
        }

        state.phase = ProposalPhase.Distributed;

        // Finalize the market (unpause pools and enable trading)
        ILauncher(_moduleRegistry[state.proposal.launcherRef]).finalize(state.market);

        emit ManualDistributionCompleted(proposalId);
    }

    function _calculateAmountAndFee(uint256 rawAmount) internal view returns (uint256 amount, uint256 fee) {
        fee = (rawAmount * protocolFee) / FEE_SCALE;
        amount = rawAmount - fee;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.DEFAULT_ADMIN_ROLE) {}
}
