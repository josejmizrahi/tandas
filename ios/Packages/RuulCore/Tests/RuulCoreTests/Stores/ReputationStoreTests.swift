import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("ReputationStore")
struct ReputationStoreTests {

    private let groupId = UUID()
    private let memberId = UUID()

    private func event(_ kind: ReputationKind, _ reason: String? = nil) -> GroupReputationEvent {
        GroupReputationEvent(id: UUID(), groupId: groupId, subjectMembershipId: memberId,
                             kind: kind, reason: reason)
    }

    private func makeStore(seed: [GroupReputationEvent]) async -> (ReputationStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setMemberReputationEventsStub(.success(seed))
        let repo = CanonicalReputationRepository(rpc: mock)
        return (ReputationStore(repository: repo), mock)
    }

    // MARK: - Refresh

    @Test("refresh loads events and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [
            event(.commitmentKept, "X"),
            event(.contributionRecognized)
        ])
        await store.refresh(groupId: groupId, subjectMembershipId: memberId)
        #expect(store.events.count == 2)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.memberReputationEvents(groupId: groupId, subjectMembershipId: memberId, limit: 50)))
    }

    @Test("refreshIfNeeded is a no-op for the same (group, member) pair")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(seed: [event(.careShown)])
        await store.refreshIfNeeded(groupId: groupId, subjectMembershipId: memberId)
        await store.refreshIfNeeded(groupId: groupId, subjectMembershipId: memberId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .memberReputationEvents = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    @Test("refreshIfNeeded refetches when the subject changes")
    func refreshIfNeededRefetchesOnSubjectChange() async {
        let (store, mock) = await makeStore(seed: [event(.careShown)])
        await store.refreshIfNeeded(groupId: groupId, subjectMembershipId: memberId)
        let otherMember = UUID()
        await store.refreshIfNeeded(groupId: groupId, subjectMembershipId: otherMember)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .memberReputationEvents = $0 { return true } else { return false } }
        #expect(calls.count == 2)
    }

    // MARK: - Failure

    @Test("refresh failure surfaces user-facing message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setMemberReputationEventsStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = ReputationStore(repository: CanonicalReputationRepository(rpc: mock))

        await store.refresh(groupId: groupId, subjectMembershipId: memberId)

        if case .failed(let message) = store.phase {
            #expect(message.isEmpty == false)
        } else {
            Issue.record("expected .failed phase, got \(store.phase)")
        }
        #expect(store.errorMessage != nil)
    }

    // MARK: - Clear

    @Test("clear resets state to idle so the next open starts fresh")
    func clearResetsState() async {
        let (store, _) = await makeStore(seed: [event(.commitmentKept)])
        await store.refresh(groupId: groupId, subjectMembershipId: memberId)
        #expect(store.events.isEmpty == false)

        store.clear()
        #expect(store.events.isEmpty)
        #expect(store.phase == .idle)
        #expect(store.errorMessage == nil)
    }
}
