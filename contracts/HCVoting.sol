pragma solidity ^0.4.24;

import "@aragon/os/contracts/common/IForwarder.sol";
import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/apps-shared-minime/contracts/MiniMeToken.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";

contract HCVoting is IForwarder, AragonApp {
    using SafeMath for uint256;

    // TODO: All uints used so far are uint256. Optimize!

    /*
     * Properties.
     */

    // Tokens used for voting and staking.
    MiniMeToken public voteToken;
    MiniMeToken public stakeToken;

    // Store proposals in a mapping, by numeric id.
    mapping (uint256 => Proposal) internal proposals;
    uint256 public numProposals;

    // Percentage required for a vote to pass with either absolute or relative majority, e.g. 50%.
    uint256 public supportPct;

    // Confidence threshold.
    // A proposal can be boosted if it's confidence, determined by staking, is above this threshold.
    uint256 public confidenceThresholdBase;

    // Lifetime of a proposal when it is not boosted.
    uint256 public queuePeriod;

    // Lifetime of a proposal when it is boosted.
    // Note: The effective lifetime of a proposal when it is boosted is dynamic, and can be extended
    // due to the requirement of quiet endings.
    uint256 public boostPeriod;
    uint256 public quietEndingPeriod;

    // Time for a pended proposal to become boosted if it maintained confidence within such period.
    uint256 public pendedBoostPeriod;

    // Compensation fee for external callers of functions that resolve and expire proposals.
    uint256 public compensationFeePct;

    // Multiplier used to avoid losing precision when using division or calculating percentages.
    uint256 internal constant PRECISION_MULTIPLIER = 10 ** 16;

    // Roles.
    bytes32 public constant CREATE_PROPOSALS_ROLE            = keccak256("CREATE_PROPOSALS_ROLE");
    bytes32 public constant MODIFY_SUPPORT_PERCENT_ROLE      = keccak256("MODIFY_SUPPORT_PERCENT_ROLE");
    bytes32 public constant MODIFY_PERIODS_ROLE              = keccak256("MODIFY_PERIODS_ROLE");
    bytes32 public constant MODIFY_COMPENSATION_FEES_ROLE    = keccak256("MODIFY_COMPENSATION_FEES_ROLE");
    bytes32 public constant MODIFY_CONFIDENCE_THRESHOLD_ROLE = keccak256("MODIFY_CONFIDENCE_THRESHOLD_ROLE");

    // Error messages.
    string internal constant ERROR_INSUFFICIENT_ALLOWANCE                    = "INSUFFICIENT_ALLOWANCE";
    string internal constant ERROR_SENDER_DOES_NOT_HAVE_REQUIRED_STAKE       = "SENDER_DOES_NOT_HAVE_REQUIRED_STAKE";
    string internal constant ERROR_PROPOSAL_DOES_NOT_HAVE_REQUIRED_STAKE     = "PROPOSAL_DOES_NOT_HAVE_REQUIRED_STAKE ";
    string internal constant ERROR_PROPOSAL_DOESNT_HAVE_ENOUGH_CONFIDENCE    = "PROPOSAL_DOESNT_HAVE_ENOUGH_CONFIDENCE";
    string internal constant ERROR_PROPOSAL_IS_NOT_BOOSTED                   = "PROPOSAL_IS_NOT_BOOSTED";
    string internal constant ERROR_PROPOSAL_IS_BOOSTED                       = "PROPOSAL_IS_BOOSTED";
    string internal constant ERROR_NO_WINNING_STAKE                          = "NO_WINNING_STAKE";
    string internal constant ERROR_PROPOSAL_HASNT_HAD_CONFIDENCE_ENOUGH_TIME = "PROPOSAL_HASNT_HAD_CONFIDENCE_ENOUGH_TIME";
    string internal constant ERROR_PROPOSAL_DOES_NOT_EXIST                   = "PROPOSAL_DOES_NOT_EXIST";
    string internal constant ERROR_PROPOSAL_IS_CLOSED                        = "PROPOSAL_IS_CLOSED";
    string internal constant ERROR_INVALID_SUPPORT_PCT                       = "ERROR_INVALID_SUPPORT_PCT";
    string internal constant ERROR_NOT_ENOUGH_SUPPORT                        = "NOT_ENOUGH_SUPPORT";
    string internal constant ERROR_PROPOSAL_IS_ACTIVE                        = "PROPOSAL_IS_ACTIVE";
    string internal constant ERROR_NO_STAKE_TO_WITHDRAW                      = "NO_STAKE_TO_WITHDRAW";
    string internal constant ERROR_CAN_NOT_FORWARD                           = "CAN_NOT_FORWARD";
    string internal constant ERROR_INSUFFICIENT_TOKENS                       = "INSUFFICIENT_TOKENS";
    
    // Vote state.
    // Absent: A vote that hasn't been made yet.
    // Yea: A positive vote signaling support for a proposal.
    // Nay: A negative vote signaling disapproval for a proposal.
    enum VoteState { Absent, Yea, Nay }

    // Proposal state.
    // Queued: A proposal that has just been created, expires in queuePeriod and can only be resolved with absolute majority.
    // Pended: A proposal that has received enough confidence at a given moment.
    // Unpended: A proposal that had been pended, but who's confindence dropped before pendedBoostPeriod elapses.
    // Resolved: A proposal that was resolved positively either by absolute or relative majority.
    // Expired: A proposal that expired, due to lack of resolution either by queuePeriod or boostPeriod elapsing.
    enum ProposalState { Queued, Unpended, Pended, Boosted, Resolved, Expired }

    // Proposal data structure.
    struct Proposal {
        uint256 snapshotBlock;
        uint256 votingPower;
        bytes executionScript;
        ProposalState state;
        uint256 lifetime;
        uint256 startDate;
        uint256 lastPendedDate;
        uint256 lastRelativeSupportFlipDate;
        VoteState lastRelativeSupport;
        uint256 yea;
        uint256 nay;
        uint256 upstake;
        uint256 downstake;
        mapping (address => VoteState) votes;
        mapping (address => uint256) upstakes;
        mapping (address => uint256) downstakes;
    }

    /*
     * Property modifiers.
     */

    function changeConfidenceThresholdBase(uint256 _confidenceThresholdBase) external auth(MODIFY_CONFIDENCE_THRESHOLD_ROLE) {
        // _validateConfidenceThresholdBase(_confidenceThresholdBase);
        confidenceThresholdBase = _confidenceThresholdBase;
    }

    function changeSupportPct(uint256 _supportPct) external auth(MODIFY_SUPPORT_PERCENT_ROLE) {
        _validateSupportPct(_supportPct);
        supportPct = _supportPct;
    }

    function changeQueuePeriod(uint256 _queuePeriod) public auth(MODIFY_PERIODS_ROLE) {
        // _validateQueuePeriod(_queuePeriod);
        queuePeriod = _queuePeriod;
    }
    
    function changeBoostPeriod(uint256 _boostPeriod) public auth(MODIFY_PERIODS_ROLE) {
        // _validateBoostPeriod(_boostPeriod);
        boostPeriod = _boostPeriod;
    }

    function changeQuietEndingPeriod(uint256 _quietEndingPeriod) public auth(MODIFY_PERIODS_ROLE) {
        // _validateQuietEndingPeriod(_quietEndingPeriod);
        quietEndingPeriod = _quietEndingPeriod;
    }

    function changePendedBoostPeriod(uint256 _pendedBoostPeriod) public auth(MODIFY_PERIODS_ROLE) {
        // _validatePendedBoostPeriod(_pendedBoostPeriod);
        pendedBoostPeriod = _pendedBoostPeriod;
    }

    function changeCompensationFeePct(uint256 _compensationFeePct) public auth(MODIFY_COMPENSATION_FEES_ROLE) {
        // _validateCompensationFeePct(_compensationFeePct);
        compensationFeePct = _compensationFeePct;
    }

    /*
     * Property validators.
     */

    function _validateSupportPct(uint256 _supportPct) internal pure {
        require(_supportPct >= 50, ERROR_INVALID_SUPPORT_PCT);
        require(_supportPct < 100, ERROR_INVALID_SUPPORT_PCT);
    }

    // function _validateQueuePeriod(uint256 _queuePeriod) internal pure {
    //     // TODO
    // }

    // function _validateBoostPeriod(uint256 _boostPeriod) internal pure {
    //     // TODO
    // }

    // function _validateQuietEndingPeriod(uint256 _quietEndingPeriod) internal pure {
    //     // TODO
    // }

    // function _validatePendedBoostPeriod(uint256 _pendedBoostPeriod) internal pure {
    //     // TODO
    // }
    
    // function _validateCompensationFeePct(uint256 _compensationFeePct) internal pure {
    //     // TODO
    // }

    // function _validateConfidenceThresholdBase(uint256 _confidenceThresholdBase) internal pure {
    //     // TODO
    // }

    /*
     * Events.
     */

    event ProposalCreated(uint256 indexed _proposalId, address indexed _creator, string _metadata);
    event ProposalStateChanged(uint256 indexed _proposalId, ProposalState _newState);
    event VoteCasted(uint256 indexed _proposalId, address indexed _voter, bool _supports, uint256 _stake);
    event ProposalLifetimeExtended(uint256 indexed _proposalId, uint256 _newLifetime);
    event UpstakeProposal(uint256 indexed _proposalId, address indexed _staker, uint256 _amount);
    event DownstakeProposal(uint256 indexed _proposalId, address indexed _staker, uint256 _amount);
    event WithdrawUpstake(uint256 indexed _proposalId, address indexed _staker, uint256 _amount);
    event WithdrawDownstake(uint256 indexed _proposalId, address indexed _staker, uint256 _amount);

    /*
     * Getters (that are not automatically injected by Solidity).
     */

    function getProposalInfo(uint256 _proposalId) public view returns (
        uint256 votingPower,
        bytes executionScript,
        ProposalState state,
        VoteState lastRelativeSupport
    ) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        votingPower = proposal_.votingPower;
        executionScript = proposal_.executionScript;
        state = proposal_.state;
        lastRelativeSupport = proposal_.lastRelativeSupport;
    }

    function getProposalTimeInfo(uint256 _proposalId) public view returns (
        uint256 snapshotBlock,
        uint256 lifetime,
        uint256 startDate,
        uint256 lastPendedDate,
        uint256 lastRelativeSupportFlipDate
    )
    {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        snapshotBlock = proposal_.snapshotBlock;
        lifetime = proposal_.lifetime;
        startDate = proposal_.startDate;
        lastPendedDate = proposal_.lastPendedDate;
        lastRelativeSupportFlipDate = proposal_.lastRelativeSupportFlipDate;
    }

    function getProposalVotes(uint256 _proposalId) public view returns (uint256 yea, uint256 nay) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        yea = proposal_.yea;
        nay = proposal_.nay;
    }

    function getProposalStakes(uint256 _proposalId) public view returns (uint256 upstake, uint256 downstake) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        upstake = proposal_.upstake;
        downstake = proposal_.downstake;
    }

    function getVote(uint256 _proposalId, address _voter) public view returns (VoteState) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        // Retrieve the voter's vote.
        Proposal storage proposal_ = proposals[_proposalId];
        return proposal_.votes[_voter];
    }

    function getUpstake(uint256 _proposalId, address _staker) public view returns (uint256) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        return proposal_.upstakes[_staker];
    }

    function getDownstake(uint256 _proposalId, address _staker) public view returns (uint256) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        return proposal_.downstakes[_staker];
    }

    function getConfidence(uint256 _proposalId) public view returns (uint256 _confidence) {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        Proposal storage proposal_ = proposals[_proposalId];
        if(proposal_.downstake == 0) _confidence = proposal_.upstake.mul(PRECISION_MULTIPLIER);
        else _confidence = proposal_.upstake.mul(PRECISION_MULTIPLIER) / proposal_.downstake;
    }

    /*
     * Initializers 
     * Note: there are is constructor, since this is intended to be used as a proxy.
     */

    function initialize(
        MiniMeToken _voteToken, 
        MiniMeToken _stakeToken, 
        uint256 _supportPct,
        uint256 _queuePeriod,
        uint256 _boostPeriod,
        uint256 _quietEndingPeriod,
        uint256 _pendedBoostPeriod,
        uint256 _compensationFeePct,
        uint256 _confidenceThresholdBase
    ) 
        external 
        onlyInit 
    {
        initialized();

        // TODO: validate tokens
        voteToken = _voteToken;
        stakeToken = _stakeToken;

        _validateSupportPct(_supportPct);
        supportPct = _supportPct;

        // _validateQueuePeriod(_queuePeriod);
        queuePeriod = _queuePeriod;

        // _validateBoostPeriod(_boostPeriod);
        boostPeriod = _boostPeriod;

        // _validateQuietEndingPeriod(_quietEndingPeriod);
        quietEndingPeriod= _quietEndingPeriod;

        // _validateCompensationFeePct(_compensationFeePct);
        compensationFeePct = _compensationFeePct;

        // _validatePendedBoostPeriod(_pendedBoostPeriod);
        pendedBoostPeriod = _pendedBoostPeriod;

        // _validateConfidenceThresholdBase(_confidenceThresholdBase);
        confidenceThresholdBase = _confidenceThresholdBase;
    }

    /*
     * Creating proposals.
     */

    function createProposal(bytes _executionScript, string _metadata) 
        public 
        auth(CREATE_PROPOSALS_ROLE)
        returns (uint256 proposalId) 
    {
        return _createProposal(_executionScript, _metadata);
    }

    function _createProposal(bytes _executionScript, string memory _metadata)
        internal
        returns (uint256 proposalId) 
    {
        // Increment proposalId.
        proposalId = numProposals;
        numProposals++;

        // Initialize proposal.
        Proposal storage proposal_ = proposals[proposalId];
        proposal_.executionScript = _executionScript;
        proposal_.startDate = now;
        proposal_.lifetime = queuePeriod;

        // Avoid double voting.
        uint256 snapshotBlock = getBlockNumber64() - 1;
        uint256 votingPower = voteToken.totalSupplyAt(snapshotBlock);
        require(votingPower > 0, ERROR_INSUFFICIENT_TOKENS);
        proposal_.votingPower = votingPower;
        proposal_.snapshotBlock = snapshotBlock;

        emit ProposalCreated(proposalId, msg.sender, _metadata);
    }

    /*
     * Voting functions.
     */

    function vote(uint256 _proposalId, bool _supports) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        require(_userHasVotingPower(_proposalId, msg.sender), ERROR_INSUFFICIENT_TOKENS);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state != ProposalState.Expired, ERROR_PROPOSAL_IS_CLOSED);
        require(proposal_.state != ProposalState.Resolved, ERROR_PROPOSAL_IS_CLOSED);

        // Get the user's voting power.
        uint256 votingPower = voteToken.balanceOfAt(msg.sender, proposal_.snapshotBlock);

        // Has the user previously voted?
        VoteState previousVote = proposal_.votes[msg.sender];

        // TODO: Can be optimized, but be careful.
        // Clean up the user's previous vote, if existent.
        if(previousVote == VoteState.Yea) {
            proposal_.yea = proposal_.yea.sub(votingPower);
        }
        else if(previousVote == VoteState.Nay) {
            proposal_.nay = proposal_.nay.sub(votingPower);
        }

        // Update the user's vote in the proposal's yea/nay count.
        if(_supports) {
            proposal_.yea = proposal_.yea.add(votingPower);
        }
        else {
            proposal_.nay = proposal_.nay.add(votingPower);
        }

        // Update the user's vote state.
        proposal_.votes[msg.sender] = _supports ? VoteState.Yea : VoteState.Nay;

        emit VoteCasted(_proposalId,msg.sender, _supports, votingPower);

        // A vote can change the state of a proposal, e.g. resolving it.
        _updateProposalAfterVoting(_proposalId);
    }

    function _updateProposalAfterVoting(uint256 _proposalId) internal {

        // Evaluate proposal resolution by absolute majority,
        // no matter if it is boosted or not.
        // Note: boosted proposals cannot auto-resolve.
        Proposal storage proposal_ = proposals[_proposalId];
        VoteState absoluteSupport = _calculateProposalSupport(proposal_, false);
        if(absoluteSupport == VoteState.Yea) {
            _updateProposalState(_proposalId, ProposalState.Resolved);
            _executeProposal(proposal_);
            return;
        }

        // If proposal is boosted, evaluate quiet endings
        // and possible extensions to its lifetime.
        if(proposal_.state == ProposalState.Boosted) {
            VoteState currentSupport = proposal_.lastRelativeSupport;
            VoteState newSupport = _calculateProposalSupport(proposal_, true);
            if(newSupport != currentSupport) {
                proposal_.lastRelativeSupportFlipDate = now;
                proposal_.lastRelativeSupport = newSupport;
                proposal_.lifetime = proposal_.lifetime.add(quietEndingPeriod);
                emit ProposalLifetimeExtended(_proposalId, proposal_.lifetime);
            }
        }
    }

    function _calculateProposalSupport(Proposal storage proposal_, bool _relative) internal view returns (VoteState) {
        uint total = _relative ? proposal_.yea.add(proposal_.nay) : proposal_.votingPower;
        uint256 yeaPct = _votesToPct(proposal_.yea, total);
        uint256 nayPct = _votesToPct(proposal_.nay, total);
        if(yeaPct > supportPct.mul(PRECISION_MULTIPLIER)) return VoteState.Yea;
        if(nayPct > supportPct.mul(PRECISION_MULTIPLIER)) return VoteState.Nay;
        return VoteState.Absent;
    }

    /*
     * Staking functions.
     */

    function stake(uint256 _proposalId, uint256 _amount, bool _supports) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);
        require(stakeToken.balanceOf(msg.sender) >= _amount, ERROR_INSUFFICIENT_TOKENS);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state != ProposalState.Expired, ERROR_PROPOSAL_IS_CLOSED);
        require(proposal_.state != ProposalState.Resolved, ERROR_PROPOSAL_IS_CLOSED);
        require(proposal_.state != ProposalState.Boosted, ERROR_PROPOSAL_IS_BOOSTED);

        // Update the proposal's stake.
        if(_supports) proposal_.upstake = proposal_.upstake.add(_amount);
        else proposal_.downstake = proposal_.downstake.add(_amount);

        // Update the staker's stake amount.
        if(_supports) proposal_.upstakes[msg.sender] = proposal_.upstakes[msg.sender].add(_amount);
        else proposal_.downstakes[msg.sender] = proposal_.downstakes[msg.sender].add(_amount);

        // Extract the tokens from the sender and store them in this contract.
        // Note: This assumes that the sender has provided the required allowance to this contract.
        require(stakeToken.allowance(msg.sender, address(this)) >= _amount, ERROR_INSUFFICIENT_ALLOWANCE);
        stakeToken.transferFrom(msg.sender, address(this), _amount);

        // Emit corresponding event.
        if(_supports) emit UpstakeProposal(_proposalId, msg.sender, _amount);
        else emit DownstakeProposal(_proposalId, msg.sender, _amount);

        // A stake can change the state of a proposal.
        _updateProposalAfterStaking(_proposalId);
    }

    function unstake(uint256 _proposalId, uint256 _amount, bool _supports) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state != ProposalState.Expired, ERROR_PROPOSAL_IS_CLOSED);
        require(proposal_.state != ProposalState.Resolved, ERROR_PROPOSAL_IS_CLOSED);

        // Verify that the sender holds the required stake to be removed.
        if(_supports) require(proposal_.upstakes[msg.sender] >= _amount, ERROR_SENDER_DOES_NOT_HAVE_REQUIRED_STAKE);
        else require(proposal_.downstakes[msg.sender] >= _amount, ERROR_SENDER_DOES_NOT_HAVE_REQUIRED_STAKE);
        
        // Verify that the proposal has the required stake to be removed.
        if(_supports) require(proposal_.upstake >= _amount, ERROR_PROPOSAL_DOES_NOT_HAVE_REQUIRED_STAKE);
        else require(proposal_.downstake >= _amount, ERROR_PROPOSAL_DOES_NOT_HAVE_REQUIRED_STAKE);

        // Remove the stake from the proposal.
        if(_supports) proposal_.upstake = proposal_.upstake.sub(_amount);
        else proposal_.downstake = proposal_.downstake.sub(_amount);

        // Remove the stake from the sender.
        if(_supports) proposal_.upstakes[msg.sender] = proposal_.upstakes[msg.sender].sub(_amount);
        else proposal_.downstakes[msg.sender] = proposal_.downstakes[msg.sender].sub(_amount);

        // Return the tokens to the sender.
        require(stakeToken.balanceOf(address(this)) >= _amount, ERROR_INSUFFICIENT_TOKENS);
        stakeToken.transfer(msg.sender, _amount);

        // Emit corresponding event.
        if(_supports) emit WithdrawUpstake(_proposalId, msg.sender, _amount);
        else emit WithdrawDownstake(_proposalId, msg.sender, _amount);

        // A stake can change the state of a proposal.
        _updateProposalAfterStaking(_proposalId);
    }

    function _updateProposalAfterStaking(uint256 _proposalId) internal {

        // If the proposal has enough confidence and it was in queue or unpended, pend it.
        // If it doesn't, unpend it.
        Proposal storage proposal_ = proposals[_proposalId];
        if(_proposalHasEnoughConfidence(_proposalId)) {
            if(proposal_.state == ProposalState.Queued || proposal_.state == ProposalState.Unpended) {
                proposal_.lastPendedDate = now;
                _updateProposalState(_proposalId, ProposalState.Pended);
            }
        }
        else {
          if(proposal_.state == ProposalState.Pended) {
                    _updateProposalState(_proposalId, ProposalState.Unpended);
          }
        }

        // TODO: Shouldn't we be able to also automatically boost proposals here?
    }

    /*
     * Boosting.
     */

    function boostProposal(uint256 _proposalId) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state != ProposalState.Expired, ERROR_PROPOSAL_IS_CLOSED);
        require(proposal_.state != ProposalState.Resolved, ERROR_PROPOSAL_IS_CLOSED);
        require(proposal_.state != ProposalState.Boosted, ERROR_PROPOSAL_IS_BOOSTED);

        // Require that the proposal is currently pended.
        require(proposal_.state == ProposalState.Pended);

        // Require that the proposal has had enough confidence for a period of time.
        require(_proposalHasEnoughConfidence(_proposalId), ERROR_PROPOSAL_DOESNT_HAVE_ENOUGH_CONFIDENCE);
        require(now >= proposal_.lastPendedDate.add(pendedBoostPeriod), ERROR_PROPOSAL_HASNT_HAD_CONFIDENCE_ENOUGH_TIME);

        // Compensate the caller.
        uint256 fee = _calculateCompensationFee(_proposalId, proposal_.lastPendedDate.add(pendedBoostPeriod));
        require(stakeToken.balanceOf(address(this)) >= fee, ERROR_INSUFFICIENT_TOKENS);
        stakeToken.transfer(msg.sender, fee);

        // Boost the proposal.
        _updateProposalState(_proposalId, ProposalState.Boosted);
        proposal_.lifetime = boostPeriod;
    }

    /*
     * Resolution functions.
     */

    function resolveBoostedProposal(uint256 _proposalId) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state == ProposalState.Boosted, ERROR_PROPOSAL_IS_NOT_BOOSTED);

        // Verify that the proposal lifetime has ended.
        require(now >= proposal_.startDate.add(proposal_.lifetime), ERROR_PROPOSAL_IS_ACTIVE);

        // Compensate the caller.
        uint256 fee = _calculateCompensationFee(_proposalId, proposal_.startDate.add(proposal_.lifetime));
        require(stakeToken.balanceOf(address(this)) >= fee, ERROR_INSUFFICIENT_TOKENS);
        stakeToken.transfer(msg.sender, fee);

        // Resolve the proposal.
        _updateProposalState(_proposalId, ProposalState.Resolved);
        _executeProposal(proposal_);
    }

    function expireNonBoostedProposal(uint256 _proposalId) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state != ProposalState.Boosted, ERROR_PROPOSAL_IS_BOOSTED);
        require(proposal_.state != ProposalState.Expired, ERROR_PROPOSAL_IS_CLOSED);

        // Verify that the proposal's lifetime has ended.
        require(now >= proposal_.startDate.add(proposal_.lifetime), ERROR_PROPOSAL_IS_ACTIVE);

        // Compensate the caller.
        uint256 fee = _calculateCompensationFee(_proposalId, proposal_.startDate.add(proposal_.lifetime));
        require(stakeToken.balanceOf(address(this)) >= fee, ERROR_INSUFFICIENT_TOKENS);
        stakeToken.transfer(msg.sender, fee);

        // Update the proposal's state and emit an event.
        _updateProposalState(_proposalId, ProposalState.Expired);
    }

    function _calculateCompensationFee(uint256 _proposalId, uint256 _cutoffDate) internal view returns(uint256 _fee) {

        // Require that the proposal has potentially expired.
        // This is necessary because the fee depends on the time since expiration.
        // If the proposal hasn't expired, the calculation would yield a negative fee.
        Proposal storage proposal_ = proposals[_proposalId];

        // Calculate fee.
        /* 
           fee
           ^
           |     ___________ max = compensationFeePct * total upstake
           |    /
           |   /
           |  /
           | /
           |/______________> time elapsed since resolution
        */
        // Note: this assumes that now > _cutoffDate, and it is the responsibility of the calling function to verify that.
        _fee = now.sub(_cutoffDate).div(compensationFeePct);
        uint256 max = proposal_.upstake.mul(PRECISION_MULTIPLIER).div(compensationFeePct);
        if(_fee.mul(PRECISION_MULTIPLIER) > max) _fee = max.div(PRECISION_MULTIPLIER);
    }

    function _executeProposal(Proposal storage proposal_) internal {
        bytes memory input = new bytes(0); // TODO: Consider input for voting scripts

        // Blacklist the stake token's address, so that
        // proposals whose scripts attempt to interact with it are not executed.
        address[] memory blacklist = new address[](1);
        blacklist[0] = address(stakeToken);

        runScript(proposal_.executionScript, input, blacklist);
    }

    /*
     * Withdrawing stake after proposals expire or resolve.
     */

    function withdrawStakeFromExpiredQueuedProposal(uint256 _proposalId) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state == ProposalState.Expired, ERROR_PROPOSAL_IS_ACTIVE);

        // Calculate the amount of that the user has staked.
        uint256 senderUpstake = proposal_.upstakes[msg.sender];
        uint256 senderDownstake = proposal_.downstakes[msg.sender];
        uint256 senderTotalStake = senderUpstake.add(senderDownstake);
        require(senderTotalStake > 0, ERROR_NO_STAKE_TO_WITHDRAW);

        // Remove the stake from the sender.
        proposal_.upstakes[msg.sender] = 0;
        proposal_.downstakes[msg.sender] = 0;

        // Return the tokens to the sender.
        require(stakeToken.balanceOf(address(this)) >= senderTotalStake, ERROR_INSUFFICIENT_TOKENS);
        stakeToken.transfer(msg.sender, senderTotalStake);
    }

    function withdrawRewardFromResolvedProposal(uint256 _proposalId) public {
        require(_proposalExists(_proposalId), ERROR_PROPOSAL_DOES_NOT_EXIST);

        Proposal storage proposal_ = proposals[_proposalId];
        require(proposal_.state == ProposalState.Resolved, ERROR_PROPOSAL_IS_ACTIVE);

        // Get proposal outcome.
        bool supported = proposal_.yea > proposal_.nay;

        // Retrieve the sender's winning stake.
        uint256 winningStake = supported ? proposal_.upstakes[msg.sender] : proposal_.downstakes[msg.sender];
        require(winningStake > 0, ERROR_NO_WINNING_STAKE);

        // Calculate the sender's reward.
        uint256 totalWinningStake = supported ? proposal_.upstake : proposal_.downstake;
        uint256 totalLosingStake = supported ? proposal_.downstake : proposal_.upstake;
        uint256 sendersWinningRatio = winningStake.mul(PRECISION_MULTIPLIER) / totalWinningStake;
        uint256 reward = sendersWinningRatio.mul(totalLosingStake) / PRECISION_MULTIPLIER;
        uint256 total = winningStake.add(reward);

        // Transfer the tokens to the winner.
        require(stakeToken.balanceOf(address(this)) >= total, ERROR_INSUFFICIENT_TOKENS);
        stakeToken.transfer(msg.sender, total);
    }

    /*
     * IForwarer interface implementation.
     */

    function isForwarder() external pure returns (bool) {
        return true;
    }

    function forward(bytes _evmScript) public {
        require(canForward(msg.sender, _evmScript), ERROR_CAN_NOT_FORWARD);
        _createProposal(_evmScript, "");
    }

    function canForward(address _sender, bytes) public view returns (bool) {
        // Note that `canPerform()` implicitly does an initialization check itself
        return canPerform(_sender, CREATE_PROPOSALS_ROLE, arr());
    }

    /*
     * Utility functions.
     */

    function _updateProposalState(uint256 _proposalId, ProposalState _newState) internal {
        Proposal storage proposal_ = proposals[_proposalId];
        if(proposal_.state != _newState) {
            proposal_.state = _newState;
            emit ProposalStateChanged(_proposalId, _newState);
        }
    }

    function _votesToPct(uint256 votes, uint256 totalVotes) internal pure returns (uint256) {
        return votes.mul(uint256(100).mul(PRECISION_MULTIPLIER)) / totalVotes;
    }

    function _userHasVotingPower(uint256 _proposalId, address _voter) internal view returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];
        return voteToken.balanceOfAt(_voter, proposal_.snapshotBlock) > 0;
    }
  
    function _proposalExists(uint256 _proposalId) internal view returns (bool) {
        return _proposalId < numProposals;
    }

    function _proposalHasEnoughConfidence(uint256 _proposalId) internal view returns (bool _hasConfidence) {
        uint256 currentConfidence = getConfidence(_proposalId);
        // TODO: The threshold should be elevated to the power of the number of currently boosted proposals.
        uint256 confidenceThreshold = confidenceThresholdBase.mul(PRECISION_MULTIPLIER);
        _hasConfidence = currentConfidence >= confidenceThreshold;
    }
}
