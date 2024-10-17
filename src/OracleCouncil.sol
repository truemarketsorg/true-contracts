// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interfaces/ITruthMarket.sol";
import "./interfaces/ITruthMarketManager.sol";
import "./interfaces/IOracleBonds.sol";
import "./interfaces/IOracleCouncil.sol";
import "./MarketEnums.sol";

contract OracleCouncil is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, IOracleCouncil {
    
    // State ////////////////////////////////////////////////////////

    uint private constant VOTING_OPTIONS = 4;

    uint private constant ACCEPT = 1;
    uint private constant RESET = 2;
    uint private constant REFUSE = 3;

    ITruthMarketManager public marketManager;
    uint public councilMemberCount;
    mapping(uint => address) public councilMemberAddress;
    mapping(address => uint) public councilMemberIndex;
    mapping(address => uint) public marketTotalDisputes;
    mapping(address => uint) public marketLastClosedDispute;
    mapping(address => uint) public allOpenDisputesCancelledToIndexForMarket;
    mapping(address => uint) public marketOpenDisputesCount;
    mapping(address => bool) public marketClosedForDisputes;
    mapping(address => address) public firstMemberThatChoseWinningPosition;

    mapping(address => mapping(uint => Dispute)) public dispute;
    mapping(address => mapping(uint => uint[])) public disputeVote;
    // keep track of whether a member has punished the disputor/resolver or not
    mapping(address => mapping(uint => bool[])) public disputeVotePunish; 
    mapping(address => mapping(uint => uint[VOTING_OPTIONS])) public disputeVotesCount;
    mapping(address => mapping(uint => uint)) public disputeWinningPositionChoosen;
    mapping(address => mapping(uint => mapping(address => uint))) public disputeWinningPositionChoosenByMember;
    mapping(address => mapping(uint => mapping(uint => uint))) public disputeWinningPositionVotes;

    // Events ////////////////////////////////////////////////////////

    event NewOracleCouncilMember(address councilMember, uint councilMemberCount);
    event OracleCouncilMemberRemoved(address councilMember, uint councilMemberCount);
    event NewMarketManager(address marketManager);
    event NewDispute(address market, string disputeString, address disputorAccount);
    event VotedAddedForDispute(address market, uint disputeIndex, uint disputeCodeVote, uint winningPosition, address voter);
    event MarketClosedForDisputes(address market, uint disputeFinalCode);
    event MarketReopenedForDisputes(address market);
    event DisputeClosed(address market, uint disputeIndex, uint decidedOption);

    // Errors ////////////////////////////////////////////////////////

    error InvalidAddress();
    error MaxOracleCouncilMembersExceeded();
    error AlreadyOracleCouncilMember();
    error OpenDisputesExist();
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

    function initialize(address _marketManager) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        marketManager = ITruthMarketManager(_marketManager);
    }

    // No receive or fallback functions

    // External functions //////////////////////////////////////////////

    function setMarketManager(address _marketManager) external onlyOwner {
        if (_marketManager == address(0)) revert InvalidAddress();
        marketManager = ITruthMarketManager(_marketManager);
        emit NewMarketManager(_marketManager);
    }

    function addOracleCouncilMember(address _councilMember) external onlyOwner {
        if (_councilMember == address(0)) revert InvalidAddress();
        if (councilMemberCount > marketManager.maxOracleCouncilMembers()) revert MaxOracleCouncilMembersExceeded();
        if (isOracleCouncilMember(_councilMember)) revert AlreadyOracleCouncilMember();
        if (_getTotalOpenDisputes() > 0) revert OpenDisputesExist();
        
        councilMemberCount = councilMemberCount + 1;
        councilMemberAddress[councilMemberCount] = _councilMember;
        councilMemberIndex[_councilMember] = councilMemberCount;
        marketManager.addPauserAddress(_councilMember);
        emit NewOracleCouncilMember(_councilMember, councilMemberCount);
    }

    function removeOracleCouncilMember(address _councilMember) external onlyOwner {
        if (!isOracleCouncilMember(_councilMember)) revert NotOracleCouncilMember();
        if (_getTotalOpenDisputes() > 0) revert OpenDisputesExist();
        
        councilMemberAddress[councilMemberIndex[_councilMember]] = councilMemberAddress[councilMemberCount];
        councilMemberIndex[councilMemberAddress[councilMemberCount]] = councilMemberIndex[_councilMember];
        councilMemberCount = councilMemberCount - 1;
        councilMemberIndex[_councilMember] = 0;
        marketManager.removePauserAddress(_councilMember);
        emit OracleCouncilMemberRemoved(_councilMember, councilMemberCount);
    }

    function openDispute(address _market, string memory _disputeString) external whenNotPaused {
        if (!marketManager.isActiveMarket(_market)) revert MarketNotActive();
        if (isMarketClosedForDisputes(_market)) revert MarketClosedForDisputesError();
        if (ITruthMarket(_market).getCurrentStatus() != MarketStatus.ResolutionProposed && 
            ITruthMarket(_market).getCurrentStatus() != MarketStatus.DisputeRaised) revert InvalidMarketStatus();
        if (keccak256(abi.encode(_disputeString)) == keccak256(abi.encode(""))) revert InvalidDisputeString();
        // return error if disputer already has an open dispute
        if (IOracleBonds(marketManager.oracleBonds()).getDisputorBondForMarket(_market, msg.sender) > 0) revert DisputeAlreadyOpen();

        marketTotalDisputes[_market] = marketTotalDisputes[_market] + 1;
        marketOpenDisputesCount[_market] = marketOpenDisputesCount[_market] + 1;
        dispute[_market][marketTotalDisputes[_market]].disputorAddress = msg.sender;
        dispute[_market][marketTotalDisputes[_market]].disputeString = _disputeString;
        dispute[_market][marketTotalDisputes[_market]].disputeTimestamp = block.timestamp;
        disputeVote[_market][marketTotalDisputes[_market]] = new uint[](councilMemberCount + 1);
        disputeVotePunish[_market][marketTotalDisputes[_market]] = new bool[](councilMemberCount + 1);
        dispute[_market][marketTotalDisputes[_market]].originalOutcomeFromResolver = ITruthMarket(_market).winningPosition();
        marketManager.disputeMarket(_market, msg.sender);
        emit NewDispute(
            _market,
            _disputeString,
            msg.sender
        );
    }

    function voteForDispute(
        address _market,
        uint _disputeIndex,
        uint _disputeCodeVote,
        bool _punish,
        uint _winningPosition
    ) external onlyCouncilMembers {
        if (!marketManager.isActiveMarket(_market)) revert MarketNotActive();
        if (isMarketClosedForDisputes(_market)) revert MarketClosedForDisputesError();
        if (_disputeIndex == 0) revert DisputeNonExistent();
        if (dispute[_market][_disputeIndex].disputeCode != 0) revert DisputeAlreadyClosed();
        if (_disputeCodeVote >= VOTING_OPTIONS || _disputeCodeVote == 0) revert InvalidDisputeCode();
        if (_disputeCodeVote == ACCEPT) {
            if (_winningPosition == 0) revert InvalidWinningPosition();
            if (_winningPosition == ITruthMarket(_market).winningPosition()) revert InvalidWinningPosition();
            if (disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender] == _winningPosition) revert SameWinningPosition();
            if (disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender] == 0) { // 0 as default value
                disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender] = _winningPosition;
                disputeWinningPositionVotes[_market][_disputeIndex][_winningPosition] = disputeWinningPositionVotes[_market][
                    _disputeIndex
                ][_winningPosition] + 1;
            } else {
                disputeWinningPositionVotes[_market][_disputeIndex][
                    disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender]
                ] = disputeWinningPositionVotes[_market][_disputeIndex][
                    disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender]
                ] - 1;
                disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender] = _winningPosition;
                disputeWinningPositionVotes[_market][_disputeIndex][_winningPosition] = disputeWinningPositionVotes[_market][
                    _disputeIndex
                ][_winningPosition] + 1;
            }
        } else {
            if (disputeVote[_market][_disputeIndex][councilMemberIndex[msg.sender]] == _disputeCodeVote) revert SameVoteOption();

            if (disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender] != 0) {
                disputeWinningPositionVotes[_market][_disputeIndex][
                    disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender]
                ] = disputeWinningPositionVotes[_market][_disputeIndex][
                    disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender]
                ] - 1;
                disputeWinningPositionChoosenByMember[_market][_disputeIndex][msg.sender] = 0;
            }
            _winningPosition = 0;
        }

        // check if already has voted for another option, and revert the vote
        if (disputeVote[_market][_disputeIndex][councilMemberIndex[msg.sender]] > 0) {
            disputeVotesCount[_market][_disputeIndex][
                disputeVote[_market][_disputeIndex][councilMemberIndex[msg.sender]]
            ] = disputeVotesCount[_market][_disputeIndex][
                disputeVote[_market][_disputeIndex][councilMemberIndex[msg.sender]]
            ] - 1;
        }

        // record the voting option
        disputeVote[_market][_disputeIndex][councilMemberIndex[msg.sender]] = _disputeCodeVote;
        disputeVotePunish[_market][_disputeIndex][councilMemberIndex[msg.sender]] = _punish;
        disputeVotesCount[_market][_disputeIndex][_disputeCodeVote] = disputeVotesCount[_market][_disputeIndex][
            _disputeCodeVote
        ] + 1;

        emit VotedAddedForDispute(_market, _disputeIndex, _disputeCodeVote, _winningPosition, msg.sender);

        if (disputeVotesCount[_market][_disputeIndex][_disputeCodeVote] > (councilMemberCount / 2)) {
            if (_disputeCodeVote == ACCEPT) {
                (uint maxVotesForPosition, uint chosenPosition) = _calculateWinningPositionBasedOnVotes(
                    _market,
                    _disputeIndex
                );
                if (maxVotesForPosition > (councilMemberCount / 2)) {
                    disputeWinningPositionChoosen[_market][_disputeIndex] = chosenPosition;
                    (bool isResolverPunished, bool isDisputorPunished) = _calculatePunishmentsBasedOnVotes(_market, _disputeIndex, _disputeCodeVote, chosenPosition);
                    _closeDispute(_market, _disputeIndex, _disputeCodeVote, chosenPosition, isResolverPunished, isDisputorPunished);
                }
            } else {
                (bool isResolverPunished, bool isDisputorPunished) = _calculatePunishmentsBasedOnVotes(_market, _disputeIndex, _disputeCodeVote, 0);
                _closeDispute(_market, _disputeIndex, _disputeCodeVote, _winningPosition, isResolverPunished, isDisputorPunished);
            }
        }
    }

    function claimUnclosedDisputeBonds(address _market, uint _disputeIndex) external whenNotPaused {
        if (!canDisputorClaimbackBondFromUnclosedDispute(_market, _disputeIndex, msg.sender)) revert UnableToClaimBond();
        IOracleBonds(marketManager.oracleBonds()).sendOpenDisputeBondFromMarketToDisputor(
            _market,
            msg.sender
        );
    }

    function closeMarketForDisputes(address _market) external {
        if (msg.sender != owner() && msg.sender != address(marketManager)) revert OnlyManagerOrOwner();
        if (marketClosedForDisputes[_market]) revert MarketClosedForDisputesError();
        marketClosedForDisputes[_market] = true;
        emit MarketClosedForDisputes(_market, 0);
    }

    function reopenMarketForDisputes(address _market) external {
        if (msg.sender != owner() && msg.sender != address(marketManager)) revert OnlyManagerOrOwner();
        if (!marketClosedForDisputes[_market]) revert MarketNotClosedForDisputes();
        marketClosedForDisputes[_market] = false;
        emit MarketReopenedForDisputes(_market);
    }

    function createMarket(
        string memory _marketQuestion,
        string memory _marketSource,
        string memory _additionalInfo,
        uint _endOfTrading,
        uint _yesNoTokenCap,
        address _rewardToken,
        uint _rewardAmount
    ) external nonReentrant whenNotPaused onlyCouncilMembers() {
        marketManager.createMarket(_marketQuestion, _marketSource, _additionalInfo, _endOfTrading, _yesNoTokenCap, _rewardToken, _rewardAmount);
    }

    function setYesNoTokenCap(address _market, uint256 _yesNoTokenCap) external onlyCouncilMembers {
        marketManager.setYesNoTokenCap(_market, _yesNoTokenCap);
    }

    function setEndOfTrading(address _market, uint256 _endOfTrading) external onlyCouncilMembers {
        marketManager.setEndOfTrading(_market, _endOfTrading);
    }
    
    function pause() external onlyOracleCouncilAndOwner {
        _pause();
    }

    function unpause() external onlyOracleCouncilAndOwner {
        _unpause();
    }

    // External view functions ////////////////////////////////////////

    function getMarketOpenDisputes(address _market) external view returns (uint) {
        return marketOpenDisputesCount[_market];
    }

    function getMarketLastClosedDispute(address _market) external view returns (uint) {
        return marketLastClosedDispute[_market];
    }

    function getNumberOfCouncilMembersForMarketDispute(address _market, uint _index) external view returns (uint) {
        return disputeVote[_market][_index].length - 1;
    }

    function getVotesMissingForMarketDispute(address _market, uint _index) external view returns (uint) {
        return disputeVote[_market][_index].length - 1 - getVotesCountForMarketDispute(_market, _index);
    }

    function getDispute(address _market, uint _index) external view returns (Dispute memory) {
        return dispute[_market][_index];
    }

    function getDisputeTimestamp(address _market, uint _index) external view returns (uint) {
        return dispute[_market][_index].disputeTimestamp;
    }

    function getDisputeAddressOfDisputor(address _market, uint _index) external view returns (address) {
        return dispute[_market][_index].disputorAddress;
    }

    function getDisputeString(address _market, uint _index) external view returns (string memory) {
        return dispute[_market][_index].disputeString;
    }

    function getDisputeCode(address _market, uint _index) external view returns (uint) {
        return dispute[_market][_index].disputeCode;
    }

    function getDisputeVotes(address _market, uint _index) external view returns (uint[] memory) {
        return disputeVote[_market][_index];
    }

    function getDisputeVoteOfCouncilMember(
        address _market,
        uint _index,
        address _councilMember
    ) external view returns (uint) {
        if (isOracleCouncilMember(_councilMember)) {
            return disputeVote[_market][_index][councilMemberIndex[_councilMember]];
        } else {
            revert NotOracleCouncilMember();
        }
    }

    function isDisputeOpen(address _market, uint _index) external view returns (bool) {
        return dispute[_market][_index].disputeCode == 0;
    }

    function isDisputeCancelled(address _market, uint _index) external view returns (bool) {
        return dispute[_market][_index].disputeCode == REFUSE;
    }

    function isOpenDisputeCancelled(address _market, uint _disputeIndex) external view returns (bool) {
        return
            (marketClosedForDisputes[_market] || _disputeIndex <= allOpenDisputesCancelledToIndexForMarket[_market]) &&
            dispute[_market][_disputeIndex].disputeCode == 0 &&
            marketLastClosedDispute[_market] != _disputeIndex;
    }

    function isMarketLastClosedDisputeExists(address _market) external view returns (bool) {
        return marketLastClosedDispute[_market] > 0;
    }

    function getLastClosedDispute(address _market) external view returns (Dispute memory) {
        return dispute[_market][marketLastClosedDispute[_market]];
    }

    
    // Public view functions ////////////////////////////////////////////

    function isOracleCouncilMember(address _councilMember) public view returns (bool) {
        return (councilMemberIndex[_councilMember] > 0);
    }

    function isMarketClosedForDisputes(address _market) public view returns (bool) {
        return marketClosedForDisputes[_market] || ITruthMarket(_market).getCurrentStatus() == MarketStatus.Finalized;
    }

    function getVotesCountForMarketDispute(address _market, uint _index) public view returns (uint) {
        uint count = 0;
        for (uint i = 1; i < disputeVote[_market][_index].length; i++) {
            count += disputeVote[_market][_index][i] > 0 ? 1 : 0;
        }
        return count;
    }

    function canDisputorClaimbackBondFromUnclosedDispute(
        address _market,
        uint _disputeIndex,
        address _disputorAddress
    ) public view returns (bool) {
        if (
            marketManager.isActiveMarket(_market) &&
            _disputeIndex <= marketTotalDisputes[_market] &&
            (marketClosedForDisputes[_market] ||
                _disputeIndex <= allOpenDisputesCancelledToIndexForMarket[_market]) &&
            dispute[_market][_disputeIndex].disputorAddress == _disputorAddress &&
            dispute[_market][_disputeIndex].disputeCode == 0 &&
            marketLastClosedDispute[_market] != _disputeIndex &&
            IOracleBonds(marketManager.oracleBonds()).getDisputorBondForMarket(_market, _disputorAddress) > 0 &&
            ITruthMarket(_market).getCurrentStatus() == MarketStatus.Finalized
        ) {
            return true;
        } else {
            return false;
        }
    }

    // Internal functions //////////////////////////////////////////////

    function _closeDispute(
        address _market,
        uint _disputeIndex,
        uint _decidedOption,
        uint _winningPosition,
        bool _isResolverPunished,
        bool _isDisputorPunished
    ) internal nonReentrant {
        if (dispute[_market][_disputeIndex].disputeCode != 0) revert DisputeAlreadyClosed();
        if (_decidedOption == 0) revert InvalidOption();

        dispute[_market][_disputeIndex].disputeCode = _decidedOption;
        dispute[_market][_disputeIndex].winningPosition = _decidedOption == REFUSE ? ITruthMarket(_market).winningPosition() : _winningPosition;
        dispute[_market][_disputeIndex].isResolverPunished = _isResolverPunished;
        dispute[_market][_disputeIndex].isDisputorPunished = _isDisputorPunished;

        marketOpenDisputesCount[_market] = marketOpenDisputesCount[_market] > 0
            ? marketOpenDisputesCount[_market] - 1
            : 0;
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

    function _calculateWinningPositionBasedOnVotes(address _market, uint _disputeIndex) internal view returns (uint, uint) {
        uint maxVotes;
        uint position;
        for (uint i = 0; i <= ITruthMarket(_market).positionCount(); i++) {
            if (disputeWinningPositionVotes[_market][_disputeIndex][i] > maxVotes) {
                maxVotes = disputeWinningPositionVotes[_market][_disputeIndex][i];
                position = i;
            }
        }

        return (maxVotes, position);
    }

    function _calculatePunishmentsBasedOnVotes(
        address _market,
        uint _disputeIndex,
        uint _disputeCodeVote,
        uint _winningPosition
    ) internal view returns (bool isResolverPunished, bool isDisputorPunished) {
        uint doPunishVotes = 0;
        uint totalValidVotes = 0;

        for (uint i = 1; i <= councilMemberCount; i++) {
            address member = councilMemberAddress[i];
            if (disputeVote[_market][_disputeIndex][i] == _disputeCodeVote &&
                (_disputeCodeVote != ACCEPT || disputeWinningPositionChoosenByMember[_market][_disputeIndex][member] == _winningPosition)) {
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

    function _getTotalOpenDisputes() internal view returns (uint) {
        uint totalOpenDisputes = 0;
        uint activeMarketsCount = marketManager.numberOfActiveMarkets();
        for (uint i = 0; i < activeMarketsCount; i++) {
            address market = marketManager.getActiveMarketAddress(i);
            if (ITruthMarket(market).getCurrentStatus() == MarketStatus.DisputeRaised) {
                totalOpenDisputes += marketOpenDisputesCount[market];
            }
        }
        return totalOpenDisputes;
    }

    // Private functions
    // (No private functions in this contract)
}