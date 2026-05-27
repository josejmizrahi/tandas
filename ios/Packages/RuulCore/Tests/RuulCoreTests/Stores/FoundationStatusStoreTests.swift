import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("FoundationStatusStore")
struct FoundationStatusStoreTests {

    private let groupId = UUID()

    private func ready() -> GroupFoundationStatus {
        GroupFoundationStatus(
            groupId: groupId,
            members: .init(status: .complete, activeCount: 3),
            boundary: .init(status: .complete, activeCount: 3, pendingInvitesCount: 0),
            purpose: .init(status: .complete, activeCount: 1),
            rules: .init(status: .complete, activeCount: 2),
            resources: .init(status: .complete, activeCount: 4),
            overallStatus: .ready
        )
    }

    private func partial() -> GroupFoundationStatus {
        GroupFoundationStatus(
            groupId: groupId,
            members: .init(status: .complete, activeCount: 1),
            boundary: .init(status: .incomplete, activeCount: 1, pendingInvitesCount: 0),
            purpose: .init(status: .incomplete, activeCount: 0),
            rules: .init(status: .incomplete, activeCount: 0),
            resources: .init(status: .incomplete, activeCount: 0),
            overallStatus: .notReady
        )
    }

    private func makeStore(_ result: Result<GroupFoundationStatus, RuulError>) async -> (FoundationStatusStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupFoundationStatusStub(result)
        let repo = CanonicalFoundationStatusRepository(rpc: mock)
        return (FoundationStatusStore(repository: repo), mock)
    }

    @Test("refresh happy path → loaded with ready status")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(.success(ready()))
        await store.refresh(groupId: groupId)
        #expect(store.phase == .loaded)
        #expect(store.isReady)
        #expect(store.completeCount == 5)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupFoundationStatus(groupId: groupId)))
    }

    @Test("refresh failure → .failed with user-facing message")
    func refreshFailure() async {
        let (store, _) = await makeStore(.failure(.backend(.mustBeAuthenticated)))
        await store.refresh(groupId: groupId)
        if case .failed(let m) = store.phase {
            #expect(!m.isEmpty)
        } else {
            Issue.record("expected .failed phase, got \(store.phase)")
        }
        #expect(store.errorMessage != nil)
    }

    @Test("refreshIfNeeded is idempotent for the same group")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(.success(ready()))
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupFoundationStatus = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    @Test("partial readiness exposes incompletePrimitives and completionRatio")
    func partialDerived() async {
        let (store, _) = await makeStore(.success(partial()))
        await store.refresh(groupId: groupId)
        #expect(store.isReady == false)
        #expect(store.incompletePrimitives.count == 4)
        #expect(store.completeCount == 1)
        #expect(abs(store.completionRatio - 0.2) < 0.0001)
    }
}
