// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./interfaces/ITruthMarket.sol";
import "./interfaces/ITruthMarketManager.sol";
import "./interfaces/IOracleBonds.sol";
import "./interfaces/IOracleCouncil.sol";
import "./MarketEnums.sol";
import "./libraries/Roles.sol";

contract OracleCouncil is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IOracleCouncil
{
    // State ////////////////////////////////////////////////////////

    uint256 private constant VOTING_OPTIONS = 4;

    uint256 private constant ACCEPT = 1;
    uint256 private constant RESET = 2;
    uint256 private constant REFUSE = 3;

    ITruthMarketManager public marketManager;
    uint256 public councilMemberCount;
    mapping(uint256 => address) public councilMemberAddress;
    mapping(address => uint256) public councilMemberIndex;
    mapping(address => uint256) public marketTotalDisputes;
    mapping(address => uint256) public marketLastClosedDispute;
    mapping(address => uint256) public allOpenDisputesCancelledToIndexForMarket;
    mapping(address => uint256) public marketOpenDisputesCount;
    mapping(address => bool) public marketClosedForDisputes;
    mapping(address => address) public firstMemberThatChoseWinningPosition;

    mapping(address => mapping(uint256 => Dispute)) public dispute;
    mapping(address => mapping(uint256 => uint256[])) public disputeVote;
    // keep track of whether a member has punished the disputor/resolver or not
    mapping(address => mapping(uint256 => bool[])) public disputeVotePunish;
    mapping(address => mapping(uint256 => uint256[VOTING_OPTIONS])) public disputeVotesCount;
    mapping(address => mapping(uint256 => uint256)) public disputeWinningPositionChoosen;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public disputeWinningPositionChoosenByMember;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public disputeWinningPositionVotes;

    // Events ////////////////////////////////////////////////////////

    event NewOracleCouncilMember(address councilMember, uint256 councilMemberCount);
    event OracleCouncilMemberRemoved(address councilMember, uint256 councilMemberCount);
    event NewMarketManager(address marketManager);
    event NewDispute(address market, string disputeString, address disputorAccount);
    event VotedAddedForDispute(
        address market, uint256 disputeIndex, uint256 disputeCodeVote, uint256 winningPosition, address voter
    );
    event MarketClosedForDisputes(address market, uint256 disputeFinalCode);
    event MarketReopenedForDisputes(address market);
    event DisputeClosed(address market, uint256 disputeIndex, uint256 decidedOption);
    event OracleCouncilMemberReplaced(
        address oldMember,
        address newMember,
        uint256 memberIndex
    );

    // Errors ////////////////////////////////////////////////////////

    error InvalidAddress();
    error MaxOracleCouncilMembersExceeded();
    error AlreadyOracleCouncilMember();
    error NotOracleCouncilMember();
    error NotOracleCouncilMemberAndOwner();
    error MarketNotActive();
    error MarketClosedForDisputesError();
    error InvalidMarketStatus();
    error InvalidDisputeString();
    error DisputeNonExistent();
    error DisputeAlreadyClosed();
    error InvalidDisputeCode();
    error InvalidWinningPosition();
    error SameWinningPosition();
    error SameVoteOption();
    error UnableToClaimBond();
    error OnlyManagerOrOwner();
    error MarketNotClosedForDisputes();
    error InvalidOption();
    error DisputeAlreadyOpen();
    error DisputeInvalid();

    // Modifiers ////////////////////////////////////////////////////////

    modifier onlyCouncilMembers() {
        if (!isOracleCouncilMember(msg.sender)) revert NotOracleCouncilMember();
        _;
    }

    modifier onlyOracleCouncilAndOwner() {
        if (!isOracleCouncilMember(msg.sender) && msg.sender != owner()) {
            revert NotOracleCouncilMemberAndOwner();
        }
        _;
    }

    // Constructor ////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with the market manager address
    /// @param _marketManager The address of the market manager contract
    function initialize(address _marketManager) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.PAUSER_ROLE, msg.sender);
        
        marketManager = ITruthMarketManager(_marketManager);
    }

    // No receive or fallback functions

    // External functions //////////////////////////////////////////////

    /// @notice Sets a new market manager address
    /// @param _marketManager The address of the new market manager contract
    function setMarketManager(address _marketManager) external onlyOwner {
        if (_marketManager == address(0)) revert InvalidAddress();
        marketManager = ITruthMarketManager(_marketManager);
        emit NewMarketManager(_marketManager);
    }

    /// @notice Adds a new member to the Oracle Council
    /// @param _councilMember The address of the new council member
    function addOracleCouncilMember(address _councilMember) external onlyOwner {
        if (_councilMember == address(0)) revert InvalidAddress();
        if (councilMemberCount > marketManager.maxOracleCouncilMembers()) revert MaxOracleCouncilMembersExceeded();
        if (isOracleCouncilMember(_councilMember)) revert AlreadyOracleCouncilMember();

        councilMemberCount = councilMemberCount + 1;
        councilMemberAddress[councilMemberCount] = _councilMember;
        councilMemberIndex[_councilMember] = councilMemberCount;
        emit NewOracleCouncilMember(_councilMember, councilMemberCount);
    }

    /// @notice Replaces an existing Oracle Council member with a new one
    /// @param _oldMember The address of the member to be replaced
    /// @param _newMember The address of the new member
    function replaceOracleCouncilMember(address _oldMember, address _newMember) external onlyOwner {
        if (_newMember == address(0)) revert InvalidAddress();
        if (_oldMember == address(0)) revert InvalidAddress();
        if (!isOracleCouncilMember(_oldMember)) revert NotOracleCouncilMember();
        if (isOracleCouncilMember(_newMember)) revert AlreadyOracleCouncilMember();
        if (_oldMember == _newMember) revert("Cannot replace with same address");
        
        uint memberIndex = councilMemberIndex[_oldMember];
        
        councilMemberAddress[memberIndex] = _newMember;
        councilMemberIndex[_newMember] = memberIndex;
        councilMemberIndex[_oldMember] = 0;
        
        emit OracleCouncilMemberReplaced(
            _oldMember,
            _newMember,
            memberIndex
        );
    }

    /// @notice Opens a new dispute for a market
    /// @param _market The address of the market to dispute
    /// @param _disputeString The reason for the dispute
    function openDispute(address _market, string memory _disputeString) external whenNotPaused {
        if (!marketManager.isActiveMarket(_market)) revert MarketNotActive();
        if (isMarketClosedForDisputes(_market)) revert MarketClosedForDisputesError();
        if (
            ITruthMarket(_market).getCurrentStatus() != MarketStatus.ResolutionProposed
                && ITruthMarket(_market).getCurrentStatus() != MarketStatus.DisputeRaised
        ) revert InvalidMarketStatus();
        if (keccak256(abi.encode(_disputeString)) == keccak256(abi.encode(""))) revert InvalidDisputeString();
        // return error if disputer already has an open dispute
        if (IOracleBonds(marketManager.oracleBonds()).getDisputorBondForMarket(_market, msg.sender) > 0) {
            revert DisputeAlreadyOpen();
        }

        marketTotalDisputes[_market] = marketTotalDisputes[_market] + 1;
        marketOpenDisputesCount[_market] = marketOpenDisputesCount[_market] + 1;
        dispute[_market][marketTotalDisputes[_market]].disputorAddress = msg.sender;
        dispute[_market][marketTotalDisputes[_market]].disputeString = _disputeString;
        dispute[_market][marketTotalDisputes[_market]].disputeTimestamp = block.timestamp;
        disputeVote[_market][marketTotalDisputes[_market]] = new uint256[](councilMemberCount + 1);
        disputeVotePunish[_market][marketTotalDisputes[_market]] = new bool[](councilMemberCount + 1);
        dispute[_market][marketTotalDisputes[_market]].originalOutcomeFromResolver =
            ITruthMarket(_market).winningPosition();
        marketManager.disputeMarket(_market, msg.sender);
        emit NewDispute(_market, _disputeString, msg.sender);
    }

    /// @notice Allows council members to vote on a dispute
    /// @param _market The address of the market with the dispute
    /// @param _disputeIndex The index of the dispute
    /// @param _disputeCodeVote The vote option (1=Accept, 2=Reset, 3=Refuse)
    /// @param _punish Whether to punish the resolver/disputor
    /// @param _winningPosition The winning position if voting to accept
    function voteForDispute(
        address _market,
        uint256 _disputeIndex,
        uint256 _disputeCodeVote,
        bool _punish,
        uint256 _winningPosition
    ) external onlyCouncilMembers {
        if (!marketManager.isActiveMarket(_market)) revert MarketNotActive();
        if (isMarketClosedForDisputes(_market)) revert MarketClosedForDisputesError();
        if (_disputeIndex <= allOpenDisputesCancelledToIndexForMarket[_market]) revert DisputeInvalid();
        if (_disputeIndex == 0) revert DisputeNonExistent();
        if (dispute[_market][_disputeIndex].disputeCode != 0) revert DisputeAlreadyClosed();
        if (_disputeCodeVote >= VOTING_OPTIONS || _disputeCodeVote == 0) revert InvalidDisputeCode();

        uint256 memberIndex = councilMemberIndex[msg.sender];
        if (memberIndex == 0) revert NotOracleCouncilMember();

        if (_disputeCodeVote == ACCEPT) {
            if (_winningPosition == 0 || 
                _winningPosition > ITruthMarket(_market).positionCount() ||
                _winningPosition == ITruthMarket(_market).winningPosition()
            ) revert InvalidWinningPosition();
            
            if (disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex] == _winningPosition) {
                revert SameWinningPosition();
            }
            if (disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex] == 0) {
                disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex] = _winningPosition;
                disputeWinningPositionVotes[_market][_disputeIndex][_winningPosition] += 1;
            } else {
                disputeWinningPositionVotes[_market][_disputeIndex][disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex]] -= 1;
                disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex] = _winningPosition;
                disputeWinningPositionVotes[_market][_disputeIndex][_winningPosition] += 1;
            }
        } else {
            if (disputeVote[_market][_disputeIndex][memberIndex] == _disputeCodeVote) {
                revert SameVoteOption();
            }

            if (disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex] != 0) {
                disputeWinningPositionVotes[_market][_disputeIndex][disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex]] -= 1;
                disputeWinningPositionChoosenByMember[_market][_disputeIndex][memberIndex] = 0;
            }
            _winningPosition = 0;
        }

        // check if already has voted for another option, and revert the vote
        if (disputeVote[_market][_disputeIndex][memberIndex] > 0) {
            disputeVotesCount[_market][_disputeIndex][disputeVote[_market][_disputeIndex][memberIndex]] = disputeVotesCount[_market][_disputeIndex][disputeVote[_market][_disputeIndex][memberIndex]] - 1;
        }

        // record the voting option
        disputeVote[_market][_disputeIndex][memberIndex] = _disputeCodeVote;
        disputeVotePunish[_market][_disputeIndex][memberIndex] = _punish;
        disputeVotesCount[_market][_disputeIndex][_disputeCodeVote] =
            disputeVotesCount[_market][_disputeIndex][_disputeCodeVote] + 1;

        emit VotedAddedForDispute(_market, _disputeIndex, _disputeCodeVote, _winningPosition, msg.sender);

        if (disputeVotesCount[_market][_disputeIndex][_disputeCodeVote] > (councilMemberCount / 2)) {
            if (_disputeCodeVote == ACCEPT) {
                (uint256 maxVotesForPosition, uint256 chosenPosition) =
                    _calculateWinningPositionBasedOnVotes(_market, _disputeIndex);
                if (maxVotesForPosition > (councilMemberCount / 2)) {
                    disputeWinningPositionChoosen[_market][_disputeIndex] = chosenPosition;
                    (bool isResolverPunished, bool isDisputorPunished) =
                        _calculatePunishmentsBasedOnVotes(_market, _disputeIndex, _disputeCodeVote, chosenPosition);
                    _closeDispute(
                        _market, _disputeIndex, _disputeCodeVote, chosenPosition, isResolverPunished, isDisputorPunished
                    );
                }
            } else {
                (bool isResolverPunished, bool isDisputorPunished) =
                    _calculatePunishmentsBasedOnVotes(_market, _disputeIndex, _disputeCodeVote, 0);
                _closeDispute(
                    _market, _disputeIndex, _disputeCodeVote, _winningPosition, isResolverPunished, isDisputorPunished
                );
            }
        }
    }

    /// @notice Allows disputors to claim back their bond from unclosed disputes
    /// @param _market The address of the market
    /// @param _disputeIndex The index of the dispute
    function claimUnclosedDisputeBonds(address _market, uint256 _disputeIndex) external whenNotPaused {
        if (!canDisputorClaimbackBondFromUnclosedDispute(_market, _disputeIndex, msg.sender)) {
            revert UnableToClaimBond();
        }
        IOracleBonds(marketManager.oracleBonds()).sendOpenDisputeBondFromMarketToDisputor(_market, msg.sender);
    }

    /// @notice Closes a market for further disputes
    /// @param _market The address of the market to close
    function closeMarketForDisputes(address _market) external {
        if (msg.sender != owner() && msg.sender != address(marketManager)) revert OnlyManagerOrOwner();
        if (marketClosedForDisputes[_market]) revert MarketClosedForDisputesError();
        marketClosedForDisputes[_market] = true;
        emit MarketClosedForDisputes(_market, 0);
    }

    /// @notice Reopens a market for disputes
    /// @param _market The address of the market to reopen
    function reopenMarketForDisputes(address _market) external {
        if (msg.sender != owner() && msg.sender != address(marketManager)) revert OnlyManagerOrOwner();
        if (!marketClosedForDisputes[_market]) revert MarketNotClosedForDisputes();
        marketClosedForDisputes[_market] = false;
        emit MarketReopenedForDisputes(_market);
    }

    /// @notice Creates a new market through the market manager
    /// @param _marketQuestion The question that the market will resolve
    /// @param _marketSource The source that will be used to verify the outcome
    /// @param _additionalInfo Additional information about the market
    /// @param _endOfTrading The timestamp when trading will end
    /// @param _yesNoTokenCap The maximum amount of YES/NO tokens that can be minted
    /// @param _rewardToken The token used for rewards
    /// @param _rewardAmount The amount of reward tokens
    /// @param _yesTokenSymbol The symbol for the YES token
    /// @param _noTokenSymbol The symbol for the NO token
    function createMarket(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint256 _endOfTrading,
        uint256 _yesNoTokenCap,
        address _rewardToken,
        uint256 _rewardAmount,
        string memory _yesTokenSymbol,
        string memory _noTokenSymbol
    ) external nonReentrant whenNotPaused onlyCouncilMembers {
        marketManager.createMarket(
            _marketQuestion,
            _marketSource,
            _additionalInfo,
            _endOfTrading,
            _yesNoTokenCap,
            _rewardToken,
            _rewardAmount,
            _yesTokenSymbol,
            _noTokenSymbol
        );
    }

    /// @notice Sets the maximum amount of YES/NO tokens that can be minted for a market
    /// @param _market The address of the market to update
    /// @param _yesNoTokenCap The new maximum token cap
    function setYesNoTokenCap(address _market, uint256 _yesNoTokenCap) external onlyCouncilMembers {
        marketManager.setYesNoTokenCap(_market, _yesNoTokenCap);
    }

    /// @notice Pauses all contract operations
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all contract operations
    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // External view functions ////////////////////////////////////////

    /// @notice Gets the number of open disputes for a market
    /// @param _market The address of the market
    /// @return uint256 The number of open disputes
    function getMarketOpenDisputes(address _market) external view returns (uint256) {
        return marketOpenDisputesCount[_market];
    }

    /// @notice Gets the index of the last closed dispute for a market
    /// @param _market The address of the market
    /// @return uint256 The index of the last closed dispute
    function getMarketLastClosedDispute(address _market) external view returns (uint256) {
        return marketLastClosedDispute[_market];
    }

    /// @notice Gets the number of council members for a specific market dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return uint256 The number of council members
    function getNumberOfCouncilMembersForMarketDispute(address _market, uint256 _index)
        external
        view
        returns (uint256)
    {
        return disputeVote[_market][_index].length - 1;
    }

    /// @notice Gets the number of missing votes for a market dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return uint256 The number of missing votes
    function getVotesMissingForMarketDispute(address _market, uint256 _index) external view returns (uint256) {
        return disputeVote[_market][_index].length - 1 - getVotesCountForMarketDispute(_market, _index);
    }

    /// @notice Gets the full dispute information
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return Dispute The dispute information
    function getDispute(address _market, uint256 _index) external view returns (Dispute memory) {
        return dispute[_market][_index];
    }

    /// @notice Gets the timestamp when a dispute was created
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return uint256 The dispute timestamp
    function getDisputeTimestamp(address _market, uint256 _index) external view returns (uint256) {
        return dispute[_market][_index].disputeTimestamp;
    }

    /// @notice Gets the address of the disputor for a specific dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return address The disputor's address
    function getDisputeAddressOfDisputor(address _market, uint256 _index) external view returns (address) {
        return dispute[_market][_index].disputorAddress;
    }

    /// @notice Gets the dispute string (reason) for a specific dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return string The dispute reason
    function getDisputeString(address _market, uint256 _index) external view returns (string memory) {
        return dispute[_market][_index].disputeString;
    }

    /// @notice Gets the dispute code (outcome) for a specific dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return uint256 The dispute code
    function getDisputeCode(address _market, uint256 _index) external view returns (uint256) {
        return dispute[_market][_index].disputeCode;
    }

    /// @notice Gets all votes for a specific dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return uint256[] Array of votes
    function getDisputeVotes(address _market, uint256 _index) external view returns (uint256[] memory) {
        return disputeVote[_market][_index];
    }

    /// @notice Gets a council member's vote for a specific dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @param _councilMember The address of the council member
    /// @return uint256 The member's vote
    function getDisputeVoteOfCouncilMember(address _market, uint256 _index, address _councilMember)
        external
        view
        returns (uint256)
    {
        if (isOracleCouncilMember(_councilMember)) {
            return disputeVote[_market][_index][councilMemberIndex[_councilMember]];
        } else {
            revert NotOracleCouncilMember();
        }
    }

    /// @notice Checks if a dispute is still open
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return bool True if the dispute is open
    function isDisputeOpen(address _market, uint256 _index) external view returns (bool) {
        return dispute[_market][_index].disputeCode == 0;
    }

    /// @notice Checks if a dispute was cancelled
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return bool True if the dispute was cancelled
    function isDisputeCancelled(address _market, uint256 _index) external view returns (bool) {
        return dispute[_market][_index].disputeCode == REFUSE;
    }

    /// @notice Checks if an open dispute was cancelled
    /// @param _market The address of the market
    /// @param _disputeIndex The index of the dispute
    /// @return bool True if the open dispute was cancelled
    function isOpenDisputeCancelled(address _market, uint256 _disputeIndex) external view returns (bool) {
        return (marketClosedForDisputes[_market] || _disputeIndex <= allOpenDisputesCancelledToIndexForMarket[_market])
            && dispute[_market][_disputeIndex].disputeCode == 0 && marketLastClosedDispute[_market] != _disputeIndex;
    }

    /// @notice Checks if a market has any closed disputes
    /// @param _market The address of the market
    /// @return bool True if the market has closed disputes
    function isMarketLastClosedDisputeExists(address _market) external view returns (bool) {
        return marketLastClosedDispute[_market] > 0;
    }

    /// @notice Gets the last closed dispute for a market
    /// @param _market The address of the market
    /// @return Dispute The last closed dispute information
    function getLastClosedDispute(address _market) external view returns (Dispute memory) {
        return dispute[_market][marketLastClosedDispute[_market]];
    }

    // Public view functions ////////////////////////////////////////////

    /// @notice Checks if a member is an Oracle Council member
    /// @param _councilMember The address of the member to check
    /// @return bool True if the member is an Oracle Council member
    function isOracleCouncilMember(address _councilMember) public view returns (bool) {
        return (councilMemberIndex[_councilMember] > 0);
    }

    /// @notice Checks if a market is closed for disputes
    /// @param _market The address of the market to check
    /// @return bool True if the market is closed for disputes
    function isMarketClosedForDisputes(address _market) public view returns (bool) {
        return marketClosedForDisputes[_market] || ITruthMarket(_market).getCurrentStatus() == MarketStatus.Finalized;
    }

    /// @notice Gets the number of votes for a specific market dispute
    /// @param _market The address of the market
    /// @param _index The index of the dispute
    /// @return uint256 The number of votes
    function getVotesCountForMarketDispute(address _market, uint256 _index) public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 1; i < disputeVote[_market][_index].length; i++) {
            count += disputeVote[_market][_index][i] > 0 ? 1 : 0;
        }
        return count;
    }

    /// @notice Checks if a disputor can claim back their bond from an unclosed dispute
    /// @param _market The address of the market
    /// @param _disputeIndex The index of the dispute
    /// @param _disputorAddress The address of the disputor
    /// @return bool True if the disputor can claim back their bond
    function canDisputorClaimbackBondFromUnclosedDispute(
        address _market,
        uint256 _disputeIndex,
        address _disputorAddress
    ) public view returns (bool) {
        if (
            marketManager.isActiveMarket(_market) && _disputeIndex <= marketTotalDisputes[_market]
                && dispute[_market][_disputeIndex].disputorAddress == _disputorAddress
                && dispute[_market][_disputeIndex].disputeCode == 0 && marketLastClosedDispute[_market] != _disputeIndex
                && IOracleBonds(marketManager.oracleBonds()).getDisputorBondForMarket(_market, _disputorAddress) > 0
                && ITruthMarket(_market).getCurrentStatus() == MarketStatus.Finalized
        ) {
            return true;
        } else {
            return false;
        }
    }

    // Internal functions //////////////////////////////////////////////

    /// @notice Closes a dispute
    /// @param _market The address of the market
    /// @param _disputeIndex The index of the dispute
    /// @param _decidedOption The decided outcome of the dispute
    /// @param _winningPosition The winning position of the dispute
    /// @param _isResolverPunished Whether the resolver is punished
    /// @param _isDisputorPunished Whether the disputor is punished
    function _closeDispute(
        address _market,
        uint256 _disputeIndex,
        uint256 _decidedOption,
        uint256 _winningPosition,
        bool _isResolverPunished,
        bool _isDisputorPunished
    ) internal nonReentrant {
        if (dispute[_market][_disputeIndex].disputeCode != 0) revert DisputeAlreadyClosed();
        if (_decidedOption == 0) revert InvalidOption();

        dispute[_market][_disputeIndex].disputeCode = _decidedOption;
        dispute[_market][_disputeIndex].winningPosition =
            _decidedOption == REFUSE ? ITruthMarket(_market).winningPosition() : _winningPosition;
        dispute[_market][_disputeIndex].isResolverPunished = _isResolverPunished;
        dispute[_market][_disputeIndex].isDisputorPunished = _isDisputorPunished;

        marketOpenDisputesCount[_market] =
            marketOpenDisputesCount[_market] > 0 ? marketOpenDisputesCount[_market] - 1 : 0;
        if (_decidedOption == REFUSE) {
            marketClosedForDisputes[_market] = true;
            marketLastClosedDispute[_market] = _disputeIndex;
            marketManager.resolveMarketByCouncil(_market, dispute[_market][_disputeIndex].originalOutcomeFromResolver);
            emit MarketClosedForDisputes(_market, _decidedOption);
        } else if (_decidedOption == ACCEPT) {
            marketClosedForDisputes[_market] = true;
            marketLastClosedDispute[_market] = _disputeIndex;
            marketManager.resolveMarketByCouncil(_market, _winningPosition);
            emit MarketClosedForDisputes(_market, _decidedOption);
        } else if (_decidedOption == RESET) {
            allOpenDisputesCancelledToIndexForMarket[_market] = marketTotalDisputes[_market];
            marketOpenDisputesCount[_market] = 0;
            marketClosedForDisputes[_market] = true;
            marketLastClosedDispute[_market] = _disputeIndex;
            marketManager.resetMarketByCouncil(_market, !_isResolverPunished);
        }
        emit DisputeClosed(_market, _disputeIndex, _decidedOption);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Internal view functions ////////////////////////////////////////

    /// @notice Calculates the winning position based on votes
    /// @param _market The address of the market
    /// @param _disputeIndex The index of the dispute
    /// @return uint256 The maximum votes and the chosen position
    function _calculateWinningPositionBasedOnVotes(address _market, uint256 _disputeIndex)
        internal
        view
        returns (uint256, uint256)
    {
        uint256 maxVotes;
        uint256 position;
        for (uint256 i = 0; i <= ITruthMarket(_market).positionCount(); i++) {
            if (disputeWinningPositionVotes[_market][_disputeIndex][i] > maxVotes) {
                maxVotes = disputeWinningPositionVotes[_market][_disputeIndex][i];
                position = i;
            }
        }

        return (maxVotes, position);
    }

    /// @notice Calculates punishments based on votes
    /// @param _market The address of the market
    /// @param _disputeIndex The index of the dispute
    /// @param _disputeCodeVote The vote option
    /// @param _winningPosition The winning position
    /// @return _isResolverPunished Whether the resolver is punished
    /// @return _isDisputorPunished Whether the disputor is punished
    function _calculatePunishmentsBasedOnVotes(
        address _market,
        uint256 _disputeIndex,
        uint256 _disputeCodeVote,
        uint256 _winningPosition
    ) internal view returns (bool _isResolverPunished, bool _isDisputorPunished) {
        uint256 doPunishVotes = 0;
        uint256 totalValidVotes = 0;

        for (uint256 i = 1; i <= councilMemberCount; i++) {
            if (
                disputeVote[_market][_disputeIndex][i] == _disputeCodeVote
                    && (
                        _disputeCodeVote != ACCEPT
                            || disputeWinningPositionChoosenByMember[_market][_disputeIndex][i] == _winningPosition
                    )
            ) {
                totalValidVotes++;
                if (disputeVotePunish[_market][_disputeIndex][i]) {
                    doPunishVotes++;
                }
            }
        }

        bool doPunish = doPunishVotes > totalValidVotes / 2;
        /*  
        1. Outcome as [Yes/No/Cancel], Slash Resolver
        2. Outcome as [Yes/No/Cancel], Not Slash Resolver
        3. Outcome as [Yes/No/Cancel], Slash Resolver
        4. Outcome as [Yes/No/Cancel], Not Slash Resolver
        5. Reset Outcome, Slash Resolver
        6. Reset Outcome, Not Slash Resolver
        7. Reject Dispute, Slash Disputer
        8. Reject Dispute, Not Slash Dispute
        */

        if (doPunish) {
            if (_disputeCodeVote == ACCEPT || _disputeCodeVote == RESET) {
                return (true, false);
            } else if (_disputeCodeVote == REFUSE) {
                return (false, true);
            }
        } else {
            return (false, false);
        }
    }

    // Private functions
    // (No private functions in this contract)
}
