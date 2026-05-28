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

    // MARK: - V2-G9 (ranked + weighted)

    @Test("ranked: beginVoting seeds voteDraftRankedOrder from options")
    func rankedBeginVotingSeedsOrder() async {
        let did = UUID()
        let opts = [
            GroupDecisionOption(id: UUID(), label: "A", sortOrder: 0),
            GroupDecisionOption(id: UUID(), label: "B", sortOrder: 1),
            GroupDecisionOption(id: UUID(), label: "C", sortOrder: 2)
        ]
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .rankedChoice, status: .open,
            options: opts
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        #expect(store.voteDraftRankedOrder == opts.map(\.id))
    }

    @Test("ranked: saveDraftVote calls cast_ranked_vote with 1-based ranks")
    func rankedSaveForwardsRankings() async {
        let did = UUID()
        let opts = [
            GroupDecisionOption(id: UUID(), label: "A", sortOrder: 0),
            GroupDecisionOption(id: UUID(), label: "B", sortOrder: 1),
            GroupDecisionOption(id: UUID(), label: "C", sortOrder: 2)
        ]
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .rankedChoice, status: .open,
            options: opts
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        // Simulated drag-to-reorder: C → A → B.
        store.voteDraftRankedOrder = [opts[2].id, opts[0].id, opts[1].id]
        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .castRankedVote(let input) = call {
                return input.pDecisionId == did
                    && input.pRankings.count == 3
                    && input.pRankings[0].optionId == opts[2].id && input.pRankings[0].rank == 1
                    && input.pRankings[1].optionId == opts[0].id && input.pRankings[1].rank == 2
                    && input.pRankings[2].optionId == opts[1].id && input.pRankings[2].rank == 3
            }
            return false
        })
    }

    @Test("ranked: saveDraftVote rejects empty rankings")
    func rankedRejectsEmpty() async {
        let did = UUID()
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .rankedChoice, status: .open
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        store.voteDraftRankedOrder = []
        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok == false)
        #expect(store.voteDraftErrorMessage != nil)
    }

    @Test("weighted: beginVoting caches strategy max_weight")
    func weightedBeginVotingCachesMax() async {
        let did = UUID()
        let opt = GroupDecisionOption(id: UUID(), label: "A", sortOrder: 0)
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .weighted, status: .open,
            options: [opt],
            weightStrategy: WeightStrategy(kind: .manual, maxWeight: 7)
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)
        store.beginVoting(on: detail)
        #expect(store.voteDraftMaxWeight == 7)
    }

    @Test("weighted: saveDraftVote forwards optionId + weight via cast_vote")
    func weightedSaveForwardsWeight() async {
        let did = UUID()
        let opt = GroupDecisionOption(id: UUID(), label: "A", sortOrder: 0)
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .weighted, status: .open,
            options: [opt],
            weightStrategy: WeightStrategy(kind: .manual, maxWeight: 10)
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        store.voteDraftOptionId = opt.id
        store.voteDraftWeights[opt.id] = 5
        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .castVote(let input) = call {
                return input.pDecisionId == did
                    && input.pOptionId == opt.id
                    && input.pWeight == 5
            }
            return false
        })
    }

    @Test("weighted: saveDraftVote rejects weight <= 0")
    func weightedRejectsZero() async {
        let did = UUID()
        let opt = GroupDecisionOption(id: UUID(), label: "A", sortOrder: 0)
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .weighted, status: .open,
            options: [opt]
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        store.voteDraftOptionId = opt.id
        store.voteDraftWeights[opt.id] = 0
        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok == false)
        #expect(store.voteDraftErrorMessage != nil)
    }

    @Test("weighted: saveDraftVote rejects weight above max")
    func weightedRejectsOverMax() async {
        let did = UUID()
        let opt = GroupDecisionOption(id: UUID(), label: "A", sortOrder: 0)
        let detail = GroupDecisionDetail(
            id: did, groupId: groupId, title: "X",
            method: .weighted, status: .open,
            options: [opt],
            weightStrategy: WeightStrategy(kind: .manual, maxWeight: 3)
        )
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        await mock.setDecisionDetailStub(.success(detail))
        await store.loadDetail(decisionId: did)

        store.beginVoting(on: detail)
        store.voteDraftOptionId = opt.id
        store.voteDraftWeights[opt.id] = 5
        let ok = await store.saveDraftVote(groupId: groupId)
        #expect(ok == false)
        #expect(store.voteDraftErrorMessage != nil)
    }

    @Test("propose weighted: draftMetadata embeds weight_strategy as nested object")
    func proposeWeightedEmbedsStrategy() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftMethod = .weighted
        store.draftWeightStrategy = WeightStrategy(kind: .manual, maxWeight: 8)

        let meta = store.draftMetadata
        #expect(meta != nil)
        if case .object(let strategy) = meta?["weight_strategy"] {
            #expect(strategy["kind"] == .string("manual"))
            if case .object(let config) = strategy["config"] {
                #expect(config["max_weight"] == .number(8))
            } else {
                Issue.record("weight_strategy.config not an object")
            }
        } else {
            Issue.record("weight_strategy not embedded as object")
        }
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
