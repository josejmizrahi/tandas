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

    @Test("draftType.sanctionAppeal requires a draftReferenceId (V2-G2 sub-slice 3)")
    func draftTypeRequiresReference() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftTitle = "Apelo"
        store.draftType = .sanctionAppeal
        #expect(store.draftNeedsReferencePick)
        #expect(store.canSaveDraftDecision == false)

        store.draftReferenceId = UUID()
        #expect(store.draftNeedsReferencePick == false)
        #expect(store.canSaveDraftDecision)
    }

    @Test("Switching draftType clears any prior reference id (V2-G2 sub-slice 3)")
    func switchingTypeClearsReference() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftType = .sanctionAppeal
        store.draftReferenceId = UUID()
        // Switch to a type with no required reference.
        store.draftType = .proposal
        #expect(store.draftReferenceId == nil)
    }

    @Test("saveDraftDecision forwards reference_kind + id to start_vote (V2-G2 sub-slice 3)")
    func saveDraftDecisionForwardsReference() async {
        let (store, mock) = await makeStore()
        let sanctionId = UUID()
        store.beginProposing()
        store.draftTitle = "Apelación"
        store.draftType = .sanctionAppeal
        store.draftReferenceId = sanctionId

        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pReferenceKind == "sanction"
                    && input.pReferenceId == sanctionId
                    && input.pDecisionType == "sanction_appeal"
            }
            return false
        })
    }

    @Test("Membership decision requires target_state metadata (V2-G2 sub-slice 4)")
    func membershipDecisionRequiresTargetState() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftTitle = "Suspender a X"
        store.draftType = .membership
        store.draftReferenceId = UUID()
        // Without target_state, cannot save.
        #expect(store.draftNeedsMembershipTargetState)
        #expect(store.canSaveDraftDecision == false)

        store.draftMembershipTargetState = .suspended
        #expect(store.draftNeedsMembershipTargetState == false)
        #expect(store.canSaveDraftDecision)
    }

    @Test("Switching away from membership clears target_state (V2-G2 sub-slice 4)")
    func switchingTypeClearsMembershipTargetState() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftType = .membership
        store.draftMembershipTargetState = .expelled
        store.draftType = .proposal
        #expect(store.draftMembershipTargetState == nil)
    }

    @Test("saveDraftDecision forwards metadata target_state to start_vote (V2-G2 sub-slice 4)")
    func saveDraftDecisionForwardsMetadata() async {
        let (store, mock) = await makeStore()
        let memberId = UUID()
        store.beginProposing()
        store.draftTitle = "Reactivar"
        store.draftType = .membership
        store.draftReferenceId = memberId
        store.draftMembershipTargetState = .active

        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pDecisionType == "membership"
                    && input.pReferenceKind == "membership"
                    && input.pReferenceId == memberId
                    && input.pMetadata == ["target_state": "active"]
            }
            return false
        })
    }

    @Test("rule_change requires both rule reference and action (V2-G2 sub-slice 5)")
    func ruleChangeRequiresActionAndRule() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftTitle = "Archivar X"
        store.draftType = .ruleChange
        #expect(store.draftNeedsReferencePick)
        store.draftReferenceId = UUID()
        #expect(store.draftNeedsRuleChangeAction)
        #expect(store.canSaveDraftDecision == false)
        store.draftRuleChangeAction = .archive
        #expect(store.canSaveDraftDecision)
    }

    @Test("saveDraftDecision forwards rule_change action metadata (V2-G2 sub-slice 5)")
    func saveDraftDecisionForwardsRuleAction() async {
        let (store, mock) = await makeStore()
        let ruleId = UUID()
        store.beginProposing()
        store.draftTitle = "Reactivar"
        store.draftType = .ruleChange
        store.draftReferenceId = ruleId
        store.draftRuleChangeAction = .activate

        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pDecisionType == "rule_change"
                    && input.pReferenceKind == "rule"
                    && input.pReferenceId == ruleId
                    && input.pMetadata == ["action": "activate"]
            }
            return false
        })
    }

    @Test("Switching away from rule_change clears action (V2-G2 sub-slice 5)")
    func switchingTypeClearsRuleChangeAction() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftType = .ruleChange
        store.draftRuleChangeAction = .archive
        store.draftType = .proposal
        #expect(store.draftRuleChangeAction == nil)
    }

    @Test("budget requires target + amount + kind (V2-G2 sub-slice 6)")
    func budgetRequiresAllFields() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftTitle = "Cuota mensual"
        store.draftType = .budget
        #expect(store.draftNeedsReferencePick) // target missing
        store.draftReferenceId = UUID()
        #expect(store.draftNeedsPoolChargeFields) // amount + kind missing
        store.draftPoolChargeAmount = "150"
        #expect(store.draftNeedsPoolChargeFields) // still need kind
        store.draftPoolChargeKind = .quota
        #expect(store.draftNeedsPoolChargeFields == false)
        #expect(store.canSaveDraftDecision)
    }

    @Test("budget rejects non-positive amounts (V2-G2 sub-slice 6)")
    func budgetRejectsBadAmount() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftTitle = "X"
        store.draftType = .budget
        store.draftReferenceId = UUID()
        store.draftPoolChargeKind = .fee
        store.draftPoolChargeAmount = "0"
        #expect(store.draftNeedsPoolChargeFields)
        store.draftPoolChargeAmount = "abc"
        #expect(store.draftNeedsPoolChargeFields)
    }

    @Test("saveDraftDecision forwards budget metadata (V2-G2 sub-slice 6)")
    func saveDraftDecisionForwardsBudgetMetadata() async {
        let (store, mock) = await makeStore()
        let target = UUID()
        store.beginProposing()
        store.draftTitle = "Cuota"
        store.draftType = .budget
        store.draftReferenceId = target
        store.draftPoolChargeAmount = "200"
        store.draftPoolChargeKind = .buyIn

        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .startVote(let input) = call {
                return input.pDecisionType == "budget"
                    && input.pReferenceKind == "pool_charge"
                    && input.pReferenceId == target
                    && input.pMetadata?["amount"] == "200"
                    && input.pMetadata?["unit"] == "MXN"
                    && input.pMetadata?["charge_kind"] == "buy_in"
            }
            return false
        })
    }

    @Test("Switching away from budget clears amount + kind (V2-G2 sub-slice 6)")
    func switchingTypeClearsBudgetFields() async {
        let (store, _) = await makeStore()
        store.beginProposing()
        store.draftType = .budget
        store.draftPoolChargeAmount = "300"
        store.draftPoolChargeKind = .quota
        store.draftType = .proposal
        #expect(store.draftPoolChargeAmount.isEmpty)
        #expect(store.draftPoolChargeKind == nil)
    }

    @Test("saveDraftDecision rejects sanction_appeal without a picked reference")
    func saveDraftRejectsMissingReference() async {
        let (store, mock) = await makeStore()
        store.beginProposing()
        store.draftTitle = "X"
        store.draftType = .sanctionAppeal
        // No draftReferenceId set.
        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok == false)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .startVote = $0 { return true } else { return false } }
        #expect(calls.isEmpty)
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
