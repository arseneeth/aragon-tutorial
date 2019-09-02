import "./ProposalBase.sol";

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/IForwarder.sol";

import "@aragon/os/contracts/lib/math/SafeMath.sol";

import "@aragon/apps-shared-minime/contracts/MiniMeToken.sol";


contract HCVoting is ProposalBase, IForwarder, AragonApp {
    using SafeMath for uint256;

    /* ROLES */

    bytes32 public constant CREATE_PROPOSALS_ROLE = keccak256("CREATE_PROPOSALS_ROLE");
    bytes32 public constant CHANGE_SUPPORT_ROLE   = keccak256("CHANGE_SUPPORT_ROLE");

    /* ERRORS */

    string internal constant ERROR_BAD_REQUIRED_SUPPORT  = "HCVOTING_BAD_REQUIRED_SUPPORT";
    string internal constant ERROR_PROPOSAL_IS_RESOLVED  = "HCVOTING_PROPOSAL_IS_RESOLVED";
    string internal constant ERROR_REDUNDANT_VOTE        = "HCVOTING_REDUNDANT_VOTE";
    string internal constant ERROR_NO_VOTING_POWER       = "HCVOTING_NO_VOTING_POWER";
    string internal constant ERROR_NO_CONSENSUS          = "HCVOTING_NO_CONSENSUS";
    string internal constant ERROR_CAN_NOT_FORWARD       = "HCVOTING_CAN_NOT_FORWARD";
    string internal constant ERROR_ALREADY_EXECUTED      = "HCVOTING_ALREADY_EXECUTED";

    /* EVENTS */

    event ProposalCreated(uint256 proposalId, address creator, string metadata);
    event VoteCasted(uint256 proposalId, address voter, bool supports);
    event ProposalExecuted(uint256 proposalId);
    event ProposalResolved(uint256 proposalId);

    /* CONSTANTS */

    // Used to avoid integer precision loss in divisions.
    uint256 internal constant MILLION = 1000000;

    /* PROPERTIES */

    MiniMeToken public voteToken;

    uint256 public requiredSupport; // Expressed as parts per million, 51% = 510000

    /* INIT */

    function initialize(MiniMeToken _voteToken, uint256 _requiredSupport) public onlyInit {
        require(_requiredSupport > 0, ERROR_BAD_REQUIRED_SUPPORT);
        require(_requiredSupport <= MILLION, ERROR_BAD_REQUIRED_SUPPORT);

        voteToken = _voteToken;
        requiredSupport = _requiredSupport;

        initialized();
    }

    /* PUBLIC */

    function create(bytes _executionScript, string _metadata) public auth(CREATE_PROPOSALS_ROLE) {
        uint64 creationBlock = getBlockNumber64() - 1;
        require(voteToken.totalSupplyAt(creationBlock) > 0, ERROR_NO_VOTING_POWER);

        uint256 proposalId = numProposals;
        numProposals++;

        Proposal storage proposal_ = _getProposal(proposalId);
        proposal_.creationBlock = creationBlock;
        proposal_.executionScript = _executionScript;

        emit ProposalCreated(proposalId, msg.sender, _metadata);
    }

    function vote(uint256 _proposalId, bool _supports) public {
        Proposal storage proposal_ = _getProposal(_proposalId);

        uint256 userVotingPower = voteToken.balanceOfAt(msg.sender, proposal_.creationBlock);
        require(userVotingPower > 0, ERROR_NO_VOTING_POWER);

        // Reject redundant votes.
        Vote previousVote = proposal_.votes[msg.sender];
        require(
            previousVote == Vote.Absent || !(previousVote == Vote.Yea && _supports || previousVote == Vote.Nay && !_supports),
            ERROR_REDUNDANT_VOTE
        );

        if (previousVote == Vote.Absent) {
            if (_supports) {
                proposal_.totalYeas = proposal_.totalYeas.add(userVotingPower);
            } else {
                proposal_.totalNays = proposal_.totalNays.add(userVotingPower);
            }
        } else {
            if (previousVote == Vote.Yea && !_supports) {
                proposal_.totalYeas = proposal_.totalYeas.sub(userVotingPower);
                proposal_.totalNays = proposal_.totalNays.add(userVotingPower);
            } else if (previousVote == Vote.Nay && _supports) {
                proposal_.totalNays = proposal_.totalNays.sub(userVotingPower);
                proposal_.totalYeas = proposal_.totalYeas.add(userVotingPower);
            }
        }

        proposal_.votes[msg.sender] = _supports ? Vote.Yea : Vote.Nay;

        emit VoteCasted(_proposalId, msg.sender, _supports);
    }

    function resolve(uint256 _proposalId) public {
        Proposal storage proposal_ = _getProposal(_proposalId);

        require(!proposal_.resolved, ERROR_PROPOSAL_IS_RESOLVED);

        Vote support = getConsensus(_proposalId);
        require(support != Vote.Absent, ERROR_NO_CONSENSUS);

        proposal_.resolved = true;

        if (support == Vote.Yea) {
            _executeProposal(_proposalId);
        }

        emit ProposalResolved(_proposalId);
    }

    /* CALCULATED PROPERTIES */

    function getConsensus(uint256 _proposalId) public view returns (Vote) {
        uint256 yeaPPM = getSupport(_proposalId, true);
        uint256 nayPPM = getSupport(_proposalId, false);

        if (yeaPPM > requiredSupport) {
            return Vote.Yea;
        }

        if (nayPPM > requiredSupport) {
            return Vote.Nay;
        }

        return Vote.Absent;
    }

    function getSupport(uint _proposalId, bool _supports) public view returns (uint256) {
        Proposal storage proposal_ = _getProposal(_proposalId);

        uint256 votingPower = voteToken.totalSupplyAt(proposal_.creationBlock);
        uint256 votes = _supports ? proposal_.totalYeas : proposal_.totalNays;

        return votes.mul(MILLION).div(votingPower);
    }

    /* INTERNAL */

    function _executeProposal(uint256 _proposalId) internal {
        Proposal storage proposal_ = _getProposal(_proposalId);
        require(!proposal_.executed, ERROR_ALREADY_EXECUTED);

        address[] memory blacklist = new address[](0);
        bytes memory input = new bytes(0);
        runScript(proposal_.executionScript, input, blacklist);

        proposal_.executed = true;

        emit ProposalExecuted(_proposalId);
    }

    /* FORWARDING */

    function isForwarder() external pure returns (bool) {
        return true;
    }

    function forward(bytes _evmScript) public {
        require(canForward(msg.sender, _evmScript), ERROR_CAN_NOT_FORWARD);
        create(_evmScript, "");
    }

    function canForward(address _sender, bytes) public view returns (bool) {
        return canPerform(_sender, CREATE_PROPOSALS_ROLE, arr());
    }

    /* SETTERS */

    /**
    * @notice Change required support to approve a proposal. Expressed in parts per million, i.e. 51% = 510000.
    * @param _newRequiredSupport uint256 New required support
    */
    function changeRequiredSupport(uint256 _newRequiredSupport) public auth(CHANGE_SUPPORT_ROLE) {
        require(_newRequiredSupport > 0, ERROR_BAD_REQUIRED_SUPPORT);
        requiredSupport = _newRequiredSupport;
    }
}
