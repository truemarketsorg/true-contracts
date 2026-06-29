// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../types/LaunchpadProposal.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/IPermit2.sol";

interface ILaunchpad {
    // Thrown when attempting to deposit or withdraw from a proposal that has already ended
    // A proposal ends either by failing (deadline reached without launch conditions met)
    // or by succeeding (launch conditions met and proposal successfully launched)
    error ProposalHasEnded();
    // general invalid arguments
    error InvalidArguments();
    // user or module blacklisted
    error Blacklisted(address entity);
    // proposal is not in the expected phase
    error InvalidPhase(ProposalPhase expected, ProposalPhase actual);

    // emitted when the protocol fee is updated
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    // emitted when the fee receiver is updated
    event FeeReceiverUpdated(address indexed previousReceiver, address indexed newReceiver);
    // emitted when a module is registered or updated
    event ModuleUpdated(bytes32 indexed name, address indexed oldModule, address indexed newModule);

    error ModuleNotRegistered(bytes32 name);
    // proposal is missing a required BinaryOutcomePlugin BeforeDeposit hook
    error MissingOutcomeRestriction();
    // proposal has too many hook bindings
    error TooManyHookBindings(uint256 count, uint256 max);
    // hook binding args exceed max length
    error HookArgsTooLarge(uint256 index, uint256 length, uint256 max);
    // emitted when a user is blacklisted or unblacklisted
    event UserBlacklistUpdated(address indexed user, bool blacklisted);
    // emitted when a proposal is created
    event ProposalCreated(uint256 indexed proposalId);
    // only emitted when depositing or withdrawing from a failed proposal
    event ProposalFailed(uint256 indexed proposalId);
    // emitted when a proposal is launched
    event ProposalLaunched(uint256 indexed proposalId, address indexed market);
    // emitted when a launch attempt fails (launch() reverted)
    event LaunchAttemptFailed(uint256 indexed proposalId);
    // emitted when a proposal is distributed. it may be deferred.
    event ProposalDistributed(uint256 indexed proposalId);
    // emitted when distribution is deferred
    event DistributionDeferred(uint256 indexed proposalId, uint256 attemptCount);
    // emitted when manual distribution is needed
    event ManualDistributionNeeded(uint256 indexed proposalId);
    // emitted when funds are withdrawn from a proposal which is in the ManualDistributionNeeded phase
    event FundsWithdrawn(uint256 indexed proposalId, address indexed receiver);
    // emitted when manual distribution is completed and pools are unpaused
    event ManualDistributionCompleted(uint256 indexed proposalId);
    // emitted when a deposit is made to a proposal
    event DepositToProposal(address indexed depositor, uint256 indexed proposalId, uint256 outcome, uint256 amount);
    // emitted when a withdrawal is made from a proposal
    event WithdrawFromProposal(address indexed withdrawer, uint256 indexed proposalId, uint256 outcome, uint256 amount);

    function protocolFee() external view returns (uint256);

    function paymentToken() external view returns (address);

    function feeReceiver() external view returns (address);

    function setProtocolFee(uint256 newFee) external;

    function setFeeReceiver(address newReceiver) external;

    function setModule(bytes32 name, address module) external;

    function resolveModule(bytes32 name) external view returns (address);

    function isUserBlacklisted(address user) external view returns (bool isBlacklisted);

    function setUserBlacklist(address user, bool blacklisted) external;

    function propose(Proposal calldata proposal) external returns (uint256 proposalId);

    function deposit(
        uint256 proposalId,
        uint256 outcome,
        uint256 amount,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;

    function withdraw(uint256 proposalId, uint256 outcome, uint256 amount) external;

    function resolveDeferredDistribution(uint256 proposalId) external;

    /// @notice Retries launching a proposal that previously failed to launch
    /// @param proposalId The ID of the proposal to retry launching
    function resolveDeferredLaunch(uint256 proposalId) external;

    /// @notice Withdraws the funds from a proposal which is in the ManualDistributionNeeded phase to a receiver
    /// @param proposalId The ID of the proposal
    /// @param receiver The address to withdraw the funds to
    function withdrawFunds(uint256 proposalId, address receiver) external;

    /// @notice Completes manual distribution by finalizing the market (unpausing pools)
    /// @dev Called after ops team has manually distributed funds off-chain
    /// @param proposalId The ID of the proposal in FundsWithdrawn phase
    function completeManualDistribution(uint256 proposalId) external;
}
