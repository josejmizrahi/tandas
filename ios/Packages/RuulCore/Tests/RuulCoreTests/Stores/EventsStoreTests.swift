import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("EventsStore")
struct EventsStoreTests {

    private let groupId = UUID()

    private func event(_ type: String,
                       summary: String? = nil,
                       at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> GroupEvent {
        GroupEvent(id: UUID(), groupId: groupId, eventType: type, summary: summary, occurredAt: at)
    }

    private func makeStore(seed: [GroupEvent] = []) async -> (EventsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupEventsRecentStub(.success(seed))
        let repo = CanonicalEventsRepository(rpc: mock)
        return (EventsStore(repository: repo), mock)
    }

    @Test("refresh loads events and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [
            event("sanction.issued", summary: "Multa"),
            event("rule.created", summary: "Nueva regla")
        ])
        await store.refresh(groupId: groupId)
        #expect(store.events.count == 2)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .groupEventsRecent(let gid, let limit, let before) = call {
                return gid == groupId && limit == 100 && before == nil
            }
            return false
        })
    }

    @Test("reachedEnd flips true when fewer rows than pageSize come back")
    func reachedEndAfterShortPage() async {
        // Seed 3 rows; page size is 100 → fewer than page = end of feed.
        let (store, _) = await makeStore(seed: [
            event("a"), event("b"), event("c")
        ])
        await store.refresh(groupId: groupId)
        #expect(store.reachedEnd)
    }

    @Test("loadMore is a no-op when reachedEnd is true")
    func loadMoreNoopAtEnd() async {
        let (store, mock) = await makeStore(seed: [event("a")])
        await store.refresh(groupId: groupId)
        #expect(store.reachedEnd)

        await store.loadMore(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupEventsRecent = $0 { return true } else { return false } }
        #expect(calls.count == 1) // only the original refresh
    }

    @Test("clear resets state to idle so re-opening starts fresh")
    func clearResetsState() async {
        let (store, _) = await makeStore(seed: [event("a")])
        await store.refresh(groupId: groupId)
        store.clear()
        #expect(store.events.isEmpty)
        #expect(store.phase == .idle)
        #expect(store.reachedEnd == false)
    }

    @Test("refresh failure surfaces user-facing message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupEventsRecentStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = EventsStore(repository: CanonicalEventsRepository(rpc: mock))

        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }
}
