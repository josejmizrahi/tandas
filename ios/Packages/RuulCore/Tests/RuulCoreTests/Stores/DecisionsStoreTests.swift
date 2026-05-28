import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("DecisionsStore")
struct DecisionsStoreTests {

    private let groupId = UUID()

    private func summary(status: DecisionStatus = .open) -> GroupDecisionSummary {
        GroupDecisionSummary(
            id: UUID(),
            groupId: groupId,
            title: "Decisión #\(Int.random(in: 1...999))",
            decisionType: .proposal,
            method: .majority,
            status: status,
            optionCount: 0,
            tally: GroupDecisionTally(voteCount: 0)
        )
    }

    private func makeStore(
        open: [GroupDecisionSummary] = [],
        history: [GroupDecisionSummary] = []
    ) async -> (DecisionsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setListDecisionsActiveStub(.success(open))
        await mock.setListDecisionsHistoryStub(.success(history))
        let repo = CanonicalDecisionsRepository(rpc: mock)
        return (DecisionsStore(repository: repo), mock)
    }

    @Test("refresh loads open + history buckets")
    func refreshHappyPath() async {
        let (store, _) = await makeStore(
            open: [summary(), summary()],
            history: [summary(status: .passed)]
        )
        await store.refresh(groupId: groupId)
        #expect(store.open.count == 2)
        #expect(store.history.count == 1)
        #expect(store.phase == .loaded)
    }

    @Test("refresh failure surfaces message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setListDecisionsActiveStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        await mock.setListDecisionsHistoryStub(.success([]))
        let store = DecisionsStore(repository: CanonicalDecisionsRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }

    @Test("saveDraftDecision sends start_vote and refreshes")
    func saveDraftDecisionSubmits() async {
        let (store, mock) = await makeStore()
        store.beginProposing()
        store.draftTitle = "  ¿Subimos cuota?  "
        store.draftBody  = "Detalle"
        store.draftMethod = .supermajority
        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        #expect(store.isProposePresented == false)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pGroupId == groupId
                    && input.pTitle == "¿Subimos cuota?"
                    && input.pBody == "Detalle"
                    && input.pMethod == "supermajority"
                    && input.pDecisionType == "proposal"
                    && input.pOptions == nil
            }
            return false
        })
    }

    @Test("saveDraftDecision rejects empty title")
    func saveDraftDecisionEmptyTitle() async {
        let (store, mock) = await makeStore()
        store.beginProposing()
        store.draftTitle = "   "
        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok == false)
        #expect(store.draftErrorMessage != nil)

        let recorded = await mock.recorded
        let calls = recorded.filter { if case .startVote = $0 { return true } else { return false } }
        #expect(calls.isEmpty)
    }

    @Test("saveDraftDecision rejects a single non-empty option (need >=2)")
    func saveDraftDecisionOptionTooFew() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftTitle = "X"
        store.draftOptions = [
            .init(label: "Sí"),
            .init(label: "   ")
        ]
        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok == false)
        #expect(store.draftErrorMessage != nil)
    }

    @Test("saveDraftDecision serialises clean two-option list")
    func saveDraftDecisionTwoOptions() async {
        let (store, mock) = await makeStore()
        store.beginProposing()
        store.draftTitle = "X"
        store.draftOptions = [
            .init(label: " Sí "),
            .init(label: "No")
        ]
        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pOptions?.count == 2
                    && input.pOptions?[0].label == "Sí"
                    && input.pOptions?[1].label == "No"
            }
            return false
        })
    }

    @Test("draftLegitimacySource auto-tracks draftMethod by default (V2-G1)")
    func legitimacyAutoSyncsWithMethod() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        #expect(store.draftLegitimacySource == .majority)

        store.draftMethod = .consensus
        #expect(store.draftLegitimacySource == .unanimity)

        store.draftMethod = .veto
        #expect(store.draftLegitimacySource == .committee)
    }

    @Test("manually picking legitimacy breaks the auto-sync until next beginProposing (V2-G1)")
    func legitimacyManualOverride() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftMethod = .supermajority      // auto → .supermajority
        store.draftLegitimacySource = .founder  // explicit override
        store.draftMethod = .majority           // should NOT clobber back to .majority
        #expect(store.draftLegitimacySource == .founder)

        // Re-opening the sheet resets the auto-sync flag.
        store.beginProposing()
        store.draftMethod = .consent
        #expect(store.draftLegitimacySource == .committee)
    }

    @Test("saveDraftDecision forwards draftLegitimacySource to start_vote (V2-G1)")
    func saveDraftDecisionForwardsLegitimacy() async {
        let (store, mock) = await makeStore()
        store.beginProposing()
        store.draftTitle = "Test"
        store.draftMethod = .rankedChoice           // auto-syncs legitimacy to .election
        store.draftLegitimacySource = .expert       // explicit override

        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pMethod == "ranked_choice"
                    && input.pLegitimacySource == "expert"
            }
            return false
        })
    }

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
        let (store, _) = await makeStore()
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
        let (store, mock) = await makeStore()
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

    @Test("finalize calls finalize_vote and refreshes")
    func finalizeRefreshes() async {
        let did = UUID()
        let (store, mock) = await makeStore()
        let ok = await store.finalize(decisionId: did, groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .finalizeVote(let id) = call { return id == did }
            return false
        })
        // refresh is implicit; the active+history stubs return empty by default
        #expect(recorded.contains { call in
            if case .listDecisionsActive(let gid) = call { return gid == groupId }
            return false
        })
    }

    @Test("loadDetail caches the detail and flips phase")
    func loadDetailHappyPath() async {
        let mock = MockRuulRPCClient()
        let did = UUID()
        let stubbed = GroupDecisionDetail(
            id: did, groupId: groupId, title: "Pizza",
            method: .majority, status: .open
        )
        await mock.setDecisionDetailStub(.success(stubbed))
        let store = DecisionsStore(repository: CanonicalDecisionsRepository(rpc: mock))
        await store.loadDetail(decisionId: did)
        #expect(store.detail?.id == did)
        #expect(store.detailPhase == .loaded)
    }
}
