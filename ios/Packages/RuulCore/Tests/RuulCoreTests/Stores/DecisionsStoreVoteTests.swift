import Foundation
import Testing
@testable import RuulCore

/// V2-G1 sub-slice 2 — covers VoteSheet semantics: allowed values per
/// method, reason-required gates for consent/veto, and the basic
/// cast_vote pipe.
@MainActor
@Suite("DecisionsStore vote")
struct DecisionsStoreVoteTests {

    private var groupId: UUID { DecisionsStoreFixture.groupId }

    @Test("saveDraftVote blocks empty reason on consent.block (V2-G1 sub-slice 2)")
    func saveDraftVoteConsentRequiresReason() async {
        let did = UUID()
        let mock = MockRuulRPCClient()
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .consent, status: .open
        )
        await mock.setDecisionDetailStub(.success(detail))
        await mock.setListDecisionsActiveStub(.success([]))
        await mock.setListDecisionsHistoryStub(.success([]))
        let store = DecisionsStore(repository: CanonicalDecisionsRepository(rpc: mock))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        store.voteDraftValue = .block
        store.voteDraftReason = "   "

        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok == false)
        #expect(store.voteDraftErrorMessage != nil)

        let recorded = await mock.recorded
        let castCalls = recorded.filter { if case .castVote = $0 { return true } else { return false } }
        #expect(castCalls.isEmpty)
    }

    @Test("saveDraftVote accepts veto block with a reason (V2-G1 sub-slice 2)")
    func saveDraftVoteVetoWithReason() async {
        let did = UUID()
        let mock = MockRuulRPCClient()
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .veto, status: .open
        )
        await mock.setDecisionDetailStub(.success(detail))
        await mock.setListDecisionsActiveStub(.success([]))
        await mock.setListDecisionsHistoryStub(.success([]))
        let store = DecisionsStore(repository: CanonicalDecisionsRepository(rpc: mock))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        store.voteDraftValue = .block
        store.voteDraftReason = "  no estoy a favor  "

        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .castVote(let input) = call {
                return input.pDecisionId == did
                    && input.pVoteValue == "block"
                    && input.pReason == "no estoy a favor"
            }
            return false
        })
    }

    @Test("beginVoting picks the first allowed value for the method (V2-G1 sub-slice 2)")
    func beginVotingPicksMethodDefault() async {
        let did = UUID()
        let (store, _) = await DecisionsStoreFixture.makeStore()
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .consent, status: .open
        )
        store.beginVoting(on: detail)
        // .consent allows [.yes, .block] → default = .yes
        #expect(store.voteDraftValue == .yes)
    }

    @Test("VoteValue.allowed and label vary by method")
    func voteValueMethodMatrix() {
        #expect(VoteValue.allowed(for: .admin) == [])
        #expect(VoteValue.allowed(for: .consensus) == [.yes, .no, .abstain])
        #expect(VoteValue.allowed(for: .consent) == [.yes, .block])
        #expect(VoteValue.allowed(for: .veto) == [.yes, .block])
        #expect(VoteValue.block.requiresReason(for: .consent))
        #expect(VoteValue.block.requiresReason(for: .veto))
        #expect(VoteValue.block.requiresReason(for: .majority) == false)
        #expect(VoteValue.no.requiresReason(for: .consensus) == false)
    }

    @Test("saveDraftVote sends cast_vote with trimmed reason")
    func saveDraftVoteSubmits() async {
        let did = UUID()
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        store.voteDraftDecisionId = did
        store.voteDraftValue = .no
        store.voteDraftOptionId = nil
        store.voteDraftReason = "  No estoy de acuerdo  "
        store.isVotePresented = true
        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok)
        #expect(store.isVotePresented == false)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .castVote(let input) = call {
                return input.pDecisionId == did
                    && input.pVoteValue == "no"
                    && input.pOptionId == nil
                    && input.pReason == "No estoy de acuerdo"
            }
            return false
        })
    }
}
