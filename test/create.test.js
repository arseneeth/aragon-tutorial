/* global artifacts contract beforeEach it assert */

const { assertRevert } = require('@aragon/test-helpers/assertThrow')
const { getEventAt } = require('@aragon/test-helpers/events')
const { deployAllAndInitializeApp } = require('./helpers/deployApp')

contract('HCVoting (create)', ([appManager, user1, user2]) => {
  let app, voteToken

  before('deploy app', async () => {
    ({ app, voteToken } = await deployAllAndInitializeApp(appManager))
  })

  describe('when no proposals exist', () => {
    it('should revert when attempting to retrieve a proposal', async () => {
      await assertRevert(
        app.getTotalYeas(0),
        'HCVOTING_PROPOSAL_DOES_NOT_EXIST'
      )
    })
  })

  describe('when no vote tokens exist', () => {
    it('should revert when attempting to create a proposal when no vote tokens exist', async () => {
      await assertRevert(
        app.create('Proposal metadata'),
        'HCVOTING_NO_VOTING_POWER'
      )
    })
  })

  describe('when vote tokens exist', () => {
    before('mint vote tokens', async () => {
      await voteToken.generateTokens(user1, 1)
    })

    describe('when a proposal is created', () => {
      let creationReceipt

      before('create a proposal', async () => {
        creationReceipt = await app.create('Proposal metadata 0', { from: user2 })
      })

      it('should store creationBlock', async () => {
        assert.equal((await app.getCreationBlock(0)).toNumber(), creationReceipt.receipt.blockNumber - 1)
      })

      it('should emit a ProposalCreated event with the appropriate data', async () => {
        const creationEvent = getEventAt(creationReceipt, 'ProposalCreated')
        assert.equal(creationEvent.args.proposalId.toNumber(), 0, 'invalid proposal id')
        assert.equal(creationEvent.args.creator, user2, 'invalid creator')
        assert.equal(creationEvent.args.metadata, 'Proposal metadata 0', 'invalid proposal metadata')
      })

      it('should increase numProposals', async () => {
        assert.equal((await app.numProposals()).toNumber(), 1)
      })

      describe('when creating another proposal', () => {
        before('create another proposal', async () => {
          creationReceipt = await app.create('Proposal metadata 1', { from: user1 })
        })

        it('should emit a ProposalCreated event with the appropriate data', async () => {
          const creationEvent = getEventAt(creationReceipt, 'ProposalCreated')
          assert.equal(creationEvent.args.proposalId.toNumber(), 1, 'invalid proposal id')
          assert.equal(creationEvent.args.creator, user1, 'invalid creator')
          assert.equal(creationEvent.args.metadata, `Proposal metadata 1`, 'invalid proposal metadata')
        })

        it('should increase numProposals', async () => {
          assert.equal((await app.numProposals()).toNumber(), 2)
        })
      })
    })
  })
})
