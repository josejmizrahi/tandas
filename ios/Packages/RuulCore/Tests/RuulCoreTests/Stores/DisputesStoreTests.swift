import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("DisputesStore")
struct DisputesStoreTests {

    private let groupId = UUID()
    private let sanctionId = UUID()

    private func dispute(_ kind: DisputeSubjectKind = .sanction,
                         status: DisputeStatus = .open,
                         title: String = "X") -> GroupDispute {
        GroupDispute(
            id: UUID(), groupId: groupId,
            subjectKind: kind, title: title, status: status
        )
    }

    private func makeStore(seed: [GroupDispute] = []) async -> (DisputesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupDisputesActiveStub(.success(seed))
        let repo = CanonicalDisputesRepository(rpc: mock)
        return (DisputesStore(repository: repo), mock)
    }

    // MARK: - Refresh

    @Test("refresh loads disputes and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [
            dispute(.sanction, status: .open),
            dispute(.rule, status: .mediation)
        ])
        await store.refresh(groupId: groupId)
        #expect(store.activeCount == 2)
        #expect(store.sanctionDisputesCount == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupDisputesActive(groupId: groupId, limit: 50)))
    }

    @Test("refreshIfNeeded is a no-op for the same group once loaded")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(seed: [dispute()])
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupDisputesActive = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    // MARK: - Dispute flow

    @Test("beginDisputingSanction primes the draft and opens the sheet")
    func beginDisputingResets() async {
        let (store, _) = await makeStore()
        store.beginDisputingSanction(sanctionId)
        #expect(store.draftSanctionId == sanctionId)
        #expect(store.draftSummary.isEmpty)
        #expect(store.isDisputeSanctionPresented)
    }

    @Test("canSaveDraft requires both sanction id and non-empty summary")
    func canSaveDraftRules() async {
        let (store, _) = await makeStore()

        store.beginDisputingSanction(sanctionId)
        #expect(store.canSaveDraft == false) // empty summary

        store.draftSummary = "   "
        #expect(store.canSaveDraft == false) // whitespace doesn't count

        store.draftSummary = "Razón razonable"
        #expect(store.canSaveDraft)
    }

    @Test("saveDraft success refreshes and dismisses the sheet")
    func saveDraftSuccess() async {
        let (store, mock) = await makeStore()
        let newDispute = dispute(.sanction, status: .open, title: "abierta")
        await mock.setDisputeSanctionStub(.success(newDispute.id))
        await mock.setGroupDisputesActiveStub(.success([newDispute]))

        store.beginDisputingSanction(sanctionId)
        store.draftSummary = "No estuve en la cena."
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok)
        #expect(store.isDisputeSanctionPresented == false)
        #expect(store.disputes.count == 1)

        let recorded = await mock.recorded
        let issued = recorded.contains { call in
            if case .disputeSanction(let input) = call {
                return input.pSanctionId == sanctionId && input.pSummary == "No estuve en la cena."
            }
            return false
        }
        #expect(issued)
    }

    @Test("saveDraft rejects empty summary locally without hitting backend")
    func saveDraftRejectsEmptyLocally() async {
        let (store, mock) = await makeStore()
        store.beginDisputingSanction(sanctionId)
        store.draftSummary = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        let recorded = await mock.recorded
        #expect(recorded.contains(where: { if case .disputeSanction = $0 { return true } else { return false } }) == false)
    }

    @Test("saveDraft surfaces backend permission error and keeps the sheet open")
    func saveDraftBackendError() async {
        let (store, mock) = await makeStore()
        await mock.setDisputeSanctionStub(.failure(.backend(.lacksPermission(permission: "sanctions.dispute", groupId: groupId))))

        store.beginDisputingSanction(sanctionId)
        store.draftSummary = "Mi razón"
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isDisputeSanctionPresented)
    }
}
