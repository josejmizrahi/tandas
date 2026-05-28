import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("ReputationFeedStore")
struct ReputationFeedStoreTests {

    private let groupId = UUID()

    private func event(_ kind: ReputationKind = .careShown) -> GroupReputationEvent {
        GroupReputationEvent(
            id: UUID(),
            groupId: groupId,
            subjectMembershipId: UUID(),
            kind: kind
        )
    }

    private func makeStore(seed: [GroupReputationEvent] = []) async -> (ReputationFeedStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupReputationEventsStub(.success(seed))
        let repo = CanonicalReputationRepository(rpc: mock)
        return (ReputationFeedStore(repository: repo), mock)
    }

    @Test("refresh loads events and lands on .loaded")
    func refreshHappyPath() async {
        let (store, _) = await makeStore(seed: [event(.careShown), event(.leadershipShown)])
        await store.refresh(groupId: groupId)
        #expect(store.events.count == 2)
        #expect(store.phase == .loaded)
    }

    @Test("saveDraft submits subject + kind + reason + visibility via record RPC")
    func saveDraftSubmits() async {
        let (store, mock) = await makeStore(seed: [])
        let subject = UUID()
        store.beginRecording(defaultSubject: subject)
        store.draftKind = .commitmentKept
        store.draftReason = "  Llegó puntual a la cena  "
        store.draftVisibility = .members
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .recordReputationEvent(let input) = call {
                return input.pGroupId == groupId
                    && input.pSubjectMembershipId == subject
                    && input.pReputationType == "commitment_kept"
                    && input.pReason == "Llegó puntual a la cena"
                    && input.pVisibility == "members"
            }
            return false
        })
    }

    @Test("saveDraft without subject surfaces error and does not call backend")
    func saveDraftNoSubject() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginRecording()
        store.draftSubjectMembershipId = nil
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .recordReputationEvent = $0 { return true } else { return false } }
        #expect(calls.isEmpty)
    }

    @Test("refresh failure surfaces message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupReputationEventsStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = ReputationFeedStore(repository: CanonicalReputationRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }
}
