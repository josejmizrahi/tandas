import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("DecisionsStore propose")
struct DecisionsStoreProposeTests {

    private var groupId: UUID { DecisionsStoreFixture.groupId }

    @Test("saveDraftDecision sends start_vote and refreshes")
    func saveDraftDecisionSubmits() async {
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
        let (store, _) = await DecisionsStoreFixture.makeStore()
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
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        #expect(store.draftLegitimacySource == .majority)

        store.draftMethod = .consensus
        #expect(store.draftLegitimacySource == .unanimity)

        store.draftMethod = .veto
        #expect(store.draftLegitimacySource == .committee)
    }

    @Test("manually picking legitimacy breaks the auto-sync until next beginProposing (V2-G1)")
    func legitimacyManualOverride() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
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

    @Test("beginProposing(defaults:) prefills draft from the group's decision rules (V2-G2 sub-slice 8)")
    func beginProposingInheritsGroupDefaults() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        let defaults = GroupDecisionRules(
            groupId: groupId,
            defaultStyle: .consensus,
            defaultMethod: .consent,
            defaultLegitimacySource: .committee,
            isDefault: false
        )
        store.beginProposing(defaults: defaults)
        #expect(store.draftMethod == .consent)
        #expect(store.draftLegitimacySource == .committee)

        // Auto-sync still works: changing the method re-derives legitimacy.
        store.draftMethod = .weighted
        #expect(store.draftLegitimacySource == .expert)
    }

    @Test("beginProposing(defaults: nil) falls back to majority/majority")
    func beginProposingFallsBackWhenNoDefaults() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing(defaults: nil)
        #expect(store.draftMethod == .majority)
        #expect(store.draftLegitimacySource == .majority)
    }

    @Test("saveDraftDecision forwards draftLegitimacySource to start_vote (V2-G1)")
    func saveDraftDecisionForwardsLegitimacy() async {
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
}
