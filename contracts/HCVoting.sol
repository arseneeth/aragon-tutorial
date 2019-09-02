import "@aragon/os/contracts/apps/AragonApp.sol";

import "@aragon/os/contracts/lib/math/SafeMath.sol";


contract HCVoting is AragonApp {
    using SafeMath for uint256;

    /* ERRORS */

    string internal constant ERROR_PROPOSAL_DOES_NOT_EXIST = "HCVOTING_PROPOSAL_DOES_NOT_EXIST";
    string internal constant ERROR_REDUNDANT_VOTE          = "HCVOTING_REDUNDANT_VOTE";

    /* EVENTS */

    event ProposalCreated(uint256 proposalId, address creator, string metadata);
    event VoteCasted(uint256 proposalId, address voter, bool supports);

    /* DATA STRUCTURES */

    enum Vote { Absent, Yea, Nay }

    struct Proposal {
        uint256 totalYeas;
        uint256 totalNays;
        mapping (address => Vote) votes;
    }

    /* PROPERTIES */

    mapping (uint256 => Proposal) proposals;
    uint256 public numProposals;

    /* INIT */

    function initialize() public onlyInit {
        initialized();
    }

    /* PUBLIC */

    function create(string _metadata) public {
        emit ProposalCreated(numProposals, msg.sender, _metadata);
        numProposals++;
    }

    function vote(uint256 _proposalId, bool _supports) public {
        Proposal storage proposal_ = _getProposal(_proposalId);

        // Reject redundant votes.
        Vote previousVote = proposal_.votes[msg.sender];
        require(
            previousVote == Vote.Absent || !(previousVote == Vote.Yea && _supports || previousVote == Vote.Nay && !_supports),
            ERROR_REDUNDANT_VOTE
        );

        if (previousVote == Vote.Absent) {
            if (_supports) {
                proposal_.totalYeas = proposal_.totalYeas.add(1);
            } else {
                proposal_.totalNays = proposal_.totalNays.add(1);
            }
        } else {
            if (previousVote == Vote.Yea && !_supports) {
                proposal_.totalYeas = proposal_.totalYeas.sub(1);
                proposal_.totalNays = proposal_.totalNays.add(1);
            } else if (previousVote == Vote.Nay && _supports) {
                proposal_.totalNays = proposal_.totalNays.sub(1);
                proposal_.totalYeas = proposal_.totalYeas.add(1);
            }
        }

        proposal_.votes[msg.sender] = _supports ? Vote.Yea : Vote.Nay;

        emit VoteCasted(_proposalId, msg.sender, _supports);
    }

    /* GETTERS */

    function getVote(uint256 _proposalId, address _user) public view returns (Vote) {
        Proposal storage proposal_ = _getProposal(_proposalId);
        return proposal_.votes[_user];
    }

    function getTotalYeas(uint256 _proposalId) public view returns (uint256) {
        Proposal storage proposal_ = _getProposal(_proposalId);
        return proposal_.totalYeas;
    }

    function getTotalNays(uint256 _proposalId) public view returns (uint256) {
        Proposal storage proposal_ = _getProposal(_proposalId);
        return proposal_.totalNays;
    }

    /* INTERNAL */

    function _getProposal(uint256 _proposalId) internal view returns (Proposal storage) {
        require(_proposalId < numProposals, ERROR_PROPOSAL_DOES_NOT_EXIST);
        return proposals[_proposalId];
    }
}
