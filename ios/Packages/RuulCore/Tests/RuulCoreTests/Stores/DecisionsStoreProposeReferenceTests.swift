import Foundation
import Testing
@testable import RuulCore

/// V2-G2 — covers the propose-side wiring of reference + per-type
/// metadata for sanction_appeal / membership / rule_change / budget.
@MainActor
@Suite("DecisionsStore propose-with-reference")
struct DecisionsStoreProposeReferenceTests {

    private var groupId: UUID { DecisionsStoreFixture.groupId }

    // MARK: - sanction_appeal (sub-slice 3)

    @Test("draftType.sanctionAppeal requires a draftReferenceId (V2-G2 sub-slice 3)")
    func draftTypeRequiresReference() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
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
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftType = .sanctionAppeal
        store.draftReferenceId = UUID()
        store.draftType = .proposal
        #expect(store.draftReferenceId == nil)
    }

    @Test("saveDraftDecision forwards reference_kind + id to start_vote (V2-G2 sub-slice 3)")
    func saveDraftDecisionForwardsReference() async {
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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

    @Test("saveDraftDecision rejects sanction_appeal without a picked reference")
    func saveDraftRejectsMissingReference() async {
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftTitle = "X"
        store.draftType = .sanctionAppeal
        let ok = await store.saveDraftDecision(groupId: groupId)
        #expect(ok == false)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .startVote = $0 { return true } else { return false } }
        #expect(calls.isEmpty)
    }

    // MARK: - membership (sub-slice 4)

    @Test("Membership decision requires target_state metadata (V2-G2 sub-slice 4)")
    func membershipDecisionRequiresTargetState() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftTitle = "Suspender a X"
        store.draftType = .membership
        store.draftReferenceId = UUID()
        #expect(store.draftNeedsMembershipTargetState)
        #expect(store.canSaveDraftDecision == false)

        store.draftMembershipTargetState = .suspended
        #expect(store.draftNeedsMembershipTargetState == false)
        #expect(store.canSaveDraftDecision)
    }

    @Test("Switching away from membership clears target_state (V2-G2 sub-slice 4)")
    func switchingTypeClearsMembershipTargetState() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftType = .membership
        store.draftMembershipTargetState = .expelled
        store.draftType = .proposal
        #expect(store.draftMembershipTargetState == nil)
    }

    @Test("saveDraftDecision forwards metadata target_state to start_vote (V2-G2 sub-slice 4)")
    func saveDraftDecisionForwardsMetadata() async {
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
                    && input.pMetadata?["target_state"] == .string("active")
            }
            return false
        })
    }

    // MARK: - rule_change (sub-slice 5)

    @Test("rule_change requires both rule reference and action (V2-G2 sub-slice 5)")
    func ruleChangeRequiresActionAndRule() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
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
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
                    && input.pMetadata?["action"] == .string("activate")
            }
            return false
        })
    }

    @Test("Switching away from rule_change clears action (V2-G2 sub-slice 5)")
    func switchingTypeClearsRuleChangeAction() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftType = .ruleChange
        store.draftRuleChangeAction = .archive
        store.draftType = .proposal
        #expect(store.draftRuleChangeAction == nil)
    }

    // MARK: - budget (sub-slice 6)

    @Test("budget requires target + amount + kind (V2-G2 sub-slice 6)")
    func budgetRequiresAllFields() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
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
        let (store, _) = await DecisionsStoreFixture.makeStore()
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
        let (store, mock) = await DecisionsStoreFixture.makeStore()
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
                    && input.pMetadata?["amount"] == .string("200")
                    && input.pMetadata?["unit"] == .string("MXN")
                    && input.pMetadata?["charge_kind"] == .string("buy_in")
            }
            return false
        })
    }

    @Test("Switching away from budget clears amount + kind (V2-G2 sub-slice 6)")
    func switchingTypeClearsBudgetFields() async {
        let (store, _) = await DecisionsStoreFixture.makeStore()
        store.beginProposing()
        store.draftType = .budget
        store.draftPoolChargeAmount = "300"
        store.draftPoolChargeKind = .quota
        store.draftType = .proposal
        #expect(store.draftPoolChargeAmount.isEmpty)
        #expect(store.draftPoolChargeKind == nil)
    }
}
