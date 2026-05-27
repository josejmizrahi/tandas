import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("SanctionsStore")
struct SanctionsStoreTests {

    private let groupId = UUID()
    private let targetId = UUID()

    private func sanction(_ kind: SanctionKind = .warning,
                          status: SanctionStatus = .active,
                          reason: String = "X") -> GroupSanction {
        GroupSanction(
            id: UUID(), groupId: groupId,
            targetMembershipId: targetId,
            targetDisplayName: "Ana",
            kind: kind, status: status,
            amount: kind == .monetary ? 500 : nil,
            unit: kind == .monetary ? "MXN" : nil,
            reason: reason
        )
    }

    private func makeStore(seed: [GroupSanction] = []) async -> (SanctionsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupSanctionsActiveStub(.success(seed))
        let repo = CanonicalSanctionsRepository(rpc: mock)
        return (SanctionsStore(repository: repo), mock)
    }

    // MARK: - Refresh

    @Test("refresh loads sanctions and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [sanction(.warning), sanction(.monetary)])
        await store.refresh(groupId: groupId)
        #expect(store.sanctions.count == 2)
        #expect(store.phase == .loaded)
        #expect(store.activeCount == 2)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupSanctionsActive(groupId: groupId, limit: 50)))
    }

    @Test("disputedCount counts only disputed status")
    func disputedCount() async {
        let (store, _) = await makeStore(seed: [
            sanction(.warning, status: .active),
            sanction(.monetary, status: .disputed),
            sanction(.repairTask, status: .disputed)
        ])
        await store.refresh(groupId: groupId)
        #expect(store.disputedCount == 2)
    }

    @Test("refreshIfNeeded is a no-op for the same group once loaded")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(seed: [sanction()])
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupSanctionsActive = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    // MARK: - Issue flow

    @Test("beginIssuing resets the draft with defaults")
    func beginIssuingResets() async {
        let (store, _) = await makeStore()
        store.beginIssuing(defaultTarget: targetId)
        #expect(store.draftTargetMembershipId == targetId)
        #expect(store.draftKind == .warning)
        #expect(store.draftReason.isEmpty)
        #expect(store.draftAmount == nil)
        #expect(store.isIssuePresented)
    }

    @Test("canSaveDraft requires target + reason; monetary also requires amount > 0 and unit")
    func canSaveDraftRules() async {
        let (store, _) = await makeStore()

        store.beginIssuing()
        #expect(store.canSaveDraft == false) // no target

        store.draftTargetMembershipId = targetId
        #expect(store.canSaveDraft == false) // no reason

        store.draftReason = "razón"
        #expect(store.canSaveDraft) // warning OK

        store.draftKind = .monetary
        #expect(store.canSaveDraft == false) // monetary w/o amount

        store.draftAmount = 100
        store.draftUnit = "MXN"
        #expect(store.canSaveDraft)

        store.draftAmount = 0
        #expect(store.canSaveDraft == false) // zero invalid

        store.draftAmount = 100
        store.draftUnit = "  "
        #expect(store.canSaveDraft == false) // empty unit invalid
    }

    @Test("saveDraft happy path refreshes and dismisses the sheet")
    func saveDraftSuccess() async {
        let (store, mock) = await makeStore()
        let newSid = UUID()
        await mock.setIssueSanctionStub(.success(newSid))
        await mock.setGroupSanctionsActiveStub(.success([sanction(.warning)]))

        store.beginIssuing(defaultTarget: targetId)
        store.draftKind = .warning
        store.draftReason = "Llegó tarde"
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok)
        #expect(store.isIssuePresented == false)
        #expect(store.sanctions.count == 1)
    }

    @Test("saveDraft propagates backend monetary-requires-amount error")
    func saveDraftMonetaryError() async {
        let (store, mock) = await makeStore()
        await mock.setIssueSanctionStub(.failure(.backend(.monetarySanctionRequiresAmountUnit)))

        store.beginIssuing(defaultTarget: targetId)
        store.draftKind = .monetary
        store.draftReason = "Faltó al fondo"
        store.draftAmount = 250
        store.draftUnit = "MXN"
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isIssuePresented)
    }

    @Test("saveDraft rejects empty reason locally without hitting backend")
    func saveDraftRejectsEmptyReasonLocally() async {
        let (store, mock) = await makeStore()
        store.beginIssuing(defaultTarget: targetId)
        store.draftKind = .warning
        store.draftReason = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        let recorded = await mock.recorded
        #expect(recorded.contains(where: { if case .issueSanction = $0 { return true } else { return false } }) == false)
    }
}
