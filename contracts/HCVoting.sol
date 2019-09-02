import "./ProposalBase.sol";

import "@aragon/os/contracts/apps/AragonApp.sol";

import "@aragon/os/contracts/lib/math/SafeMath.sol";

import "@aragon/apps-shared-minime/contracts/MiniMeToken.sol";


contract HCVoting is ProposalBase, AragonApp {
    using SafeMath for uint256;

    /* ERRORS */

    string internal constant ERROR_BAD_REQUIRED_SUPPORT  = "HCVOTING_BAD_REQUIRED_SUPPORT";
    string internal constant ERROR_PROPOSAL_IS_RESOLVED  = "HCVOTING_PROPOSAL_IS_RESOLVED";
    string internal constant ERROR_REDUNDANT_VOTE        = "HCVOTING_REDUNDANT_VOTE";
    string internal constant ERROR_NO_VOTING_POWER       = "HCVOTING_NO_VOTING_POWER";
    string internal constant ERROR_NO_CONSENSUS          = "HCVOTING_NO_CONSENSUS";

    /* EVENTS */

    event ProposalCreated(uint256 proposalId, address creator, string metadata);
    event VoteCasted(uint256 proposalId, address voter, bool supports);
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

    function create(string _metadata) public {
        emit ProposalCreated(numProposals, msg.sender, _metadata);
        numProposals++;
    }

    function vote(uint256 _proposalId, bool _supports) public {
        Proposal storage proposal_ = _getProposal(_proposalId);

        uint256 userVotingPower = voteToken.balanceOf(msg.sender);
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

        uint256 votingPower = voteToken.totalSupply();
        uint256 votes = _supports ? proposal_.totalYeas : proposal_.totalNays;

        return votes.mul(MILLION).div(votingPower);
    }
}
