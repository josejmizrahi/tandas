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

    // MARK: - C2: detail + open + append + resolve + escalate

    @Test("loadDetail caches detail + events and flips phase")
    func loadDetailHappyPath() async {
        let mock = MockRuulRPCClient()
        let did = UUID()
        let det = GroupDisputeDetail(id: did, groupId: groupId, title: "Pizza")
        let evt = GroupDisputeEvent(
            id: UUID(), disputeId: did,
            eventType: .comment, body: "primero"
        )
        await mock.setDisputeDetailStub(.success(det))
        await mock.setListDisputeEventsStub(.success([evt]))
        let store = DisputesStore(repository: CanonicalDisputesRepository(rpc: mock))
        await store.loadDetail(disputeId: did)
        #expect(store.detail?.id == did)
        #expect(store.events.count == 1)
        #expect(store.detailPhase == .loaded)
    }

    @Test("saveOpenDraft sends open_dispute and refreshes the list")
    func saveOpenDraftSubmits() async {
        let (store, mock) = await makeStore()
        store.beginOpeningDispute(subjectKind: .other)
        store.openDraftTitle = "  Conflicto con el viaje  "
        store.openDraftDescription = "Detalle"
        let ok = await store.saveOpenDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isOpenPresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .openDispute(let input) = call {
                return input.pGroupId == groupId
                    && input.pTitle == "Conflicto con el viaje"
                    && input.pSubjectKind == "other"
                    && input.pDescription == "Detalle"
            }
            return false
        })
    }

    @Test("saveOpenDraft rejects empty title locally")
    func saveOpenDraftEmptyTitle() async {
        let (store, mock) = await makeStore()
        store.beginOpeningDispute()
        store.openDraftTitle = "   "
        let ok = await store.saveOpenDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.openDraftErrorMessage != nil)
        let recorded = await mock.recorded
        let opens = recorded.filter { if case .openDispute = $0 { return true } else { return false } }
        #expect(opens.isEmpty)
    }

    @Test("saveEventDraft sends append_dispute_event with trimmed body")
    func saveEventDraftSubmits() async {
        let did = UUID()
        let mock = MockRuulRPCClient()
        await mock.setGroupDisputesActiveStub(.success([]))
        let store = DisputesStore(repository: CanonicalDisputesRepository(rpc: mock))
        store.beginAppendingEvent(disputeId: did, defaultType: .evidenceAdded)
        store.eventDraftBody = "  La foto del recibo  "
        let ok = await store.saveEventDraft()
        #expect(ok)
        #expect(store.isAppendEventPresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .appendDisputeEvent(let input) = call {
                return input.pDisputeId == did
                    && input.pEventType == "evidence_added"
                    && input.pBody == "La foto del recibo"
            }
            return false
        })
    }

    @Test("saveResolveDraft sends record_dispute_resolution and refreshes")
    func saveResolveDraftSubmits() async {
        let did = UUID()
        let (store, mock) = await makeStore()
        store.beginResolving(disputeId: did)
        store.resolveDraftMethod = .conversation
        store.resolveDraftText = "Acuerdo verbal"
        let ok = await store.saveResolveDraft(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .recordDisputeResolution(let input) = call {
                return input.pDisputeId == did
                    && input.pMethod == "conversation"
                    && input.pResolutionText == "Acuerdo verbal"
            }
            return false
        })
    }

    @Test("saveEscalateDraft sends escalate_dispute_to_vote and stores last decision id")
    func saveEscalateDraftSubmits() async {
        let did = UUID()
        let decisionId = UUID()
        let mock = MockRuulRPCClient()
        await mock.setGroupDisputesActiveStub(.success([]))
        await mock.setEscalateDisputeToVoteStub(.success(decisionId))
        let store = DisputesStore(repository: CanonicalDisputesRepository(rpc: mock))
        store.beginEscalating(disputeId: did, suggestedTitle: "Disputa")
        store.escalateDraftMethod = .supermajority
        let ok = await store.saveEscalateDraft(groupId: groupId)
        #expect(ok)
        #expect(store.lastEscalatedDecisionId == decisionId)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .escalateDisputeToVote(let input) = call {
                return input.pDisputeId == did
                    && input.pDecisionMethod == "supermajority"
                    && input.pDecisionTitle == "Disputa"
            }
            return false
        })
    }

    @Test("saveEscalateDraft rejects past closes_at")
    func saveEscalatePastDate() async {
        let did = UUID()
        let (store, _) = await makeStore()
        store.beginEscalating(disputeId: did, suggestedTitle: "X")
        store.escalateDraftHasCloseDate = true
        store.escalateDraftClosesAt = Date().addingTimeInterval(-3600)
        let ok = await store.saveEscalateDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.escalateDraftErrorMessage != nil)
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
