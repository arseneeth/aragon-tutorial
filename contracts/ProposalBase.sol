pragma solidity ^0.4.24;

contract ProposalBase {

    /* ERRORS */

    string internal constant ERROR_PROPOSAL_DOES_NOT_EXIST = "HCVOTING_PROPOSAL_DOES_NOT_EXIST";

    /* DATA STRUCTURES */

    enum Vote { Absent, Yea, Nay }

    struct Proposal {
        bool resolved;
        uint64 creationBlock;
        uint256 totalYeas;
        uint256 totalNays;
        mapping (address => Vote) votes;
    }

    /* PROPERTIES */

    mapping (uint256 => Proposal) proposals;
    uint256 public numProposals;

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

    function getResolved(uint256 _proposalId) public view returns (bool) {
        Proposal storage proposal_ = _getProposal(_proposalId);
        return proposal_.resolved;
    }

    function getCreationBlock(uint256 _proposalId) public view returns (uint256) {
        Proposal storage proposal_ = _getProposal(_proposalId);
        return proposal_.creationBlock;
    }

    /* INTERNAL */

    function _getProposal(uint256 _proposalId) internal view returns (Proposal storage) {
        require(_proposalId < numProposals, ERROR_PROPOSAL_DOES_NOT_EXIST);
        return proposals[_proposalId];
    }
}
