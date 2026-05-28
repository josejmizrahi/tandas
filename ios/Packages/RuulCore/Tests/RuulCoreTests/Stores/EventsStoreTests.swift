import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("EventsStore")
struct EventsStoreTests {

    private let groupId = UUID()

    private func event(_ type: String,
                       summary: String? = nil,
                       entityKind: String? = nil,
                       entityId: UUID? = nil,
                       actor: String? = nil,
                       at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> GroupEvent {
        GroupEvent(
            id: UUID(),
            groupId: groupId,
            actorDisplayName: actor,
            eventType: type,
            entityKind: entityKind,
            entityId: entityId,
            summary: summary,
            occurredAt: at
        )
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

    @Test("selectedCategory filters visibleEvents by eventType prefix + entityKind")
    func categoryFiltersVisibleEvents() async {
        let (store, _) = await makeStore(seed: [
            event("sanction.issued", summary: "Multa"),
            event("rule.created", summary: "Regla nueva"),
            event("expense.recorded", summary: "Gasto", entityKind: "transaction"),
            event("dispute.opened", summary: "Disputa"),
            event("cultural_norm.proposed", summary: "Norma")
        ])
        await store.refresh(groupId: groupId)

        store.setCategory(.money)
        #expect(store.visibleEvents.count == 1)
        #expect(store.visibleEvents.first?.summary == "Gasto")

        store.setCategory(.disputes)
        #expect(store.visibleEvents.count == 1)
        #expect(store.visibleEvents.first?.summary == "Disputa")

        // Tapping the active chip again clears the filter.
        store.setCategory(.disputes)
        #expect(store.selectedCategory == nil)
        #expect(store.visibleEvents.count == 5)
    }

    @Test("searchQuery filters visibleEvents on summary, actor and eventType")
    func searchQueryFiltersAcrossFields() async {
        let (store, _) = await makeStore(seed: [
            event("rule.created", summary: "Nueva regla", actor: "Ana"),
            event("sanction.issued", summary: "Multa por retraso", actor: "Beto"),
            event("expense.recorded", summary: "Gasto comida", actor: "Carla")
        ])
        await store.refresh(groupId: groupId)

        store.searchQuery = "multa"
        #expect(store.visibleEvents.count == 1)
        #expect(store.visibleEvents.first?.summary == "Multa por retraso")

        store.searchQuery = "ana"           // actor match
        #expect(store.visibleEvents.count == 1)
        #expect(store.visibleEvents.first?.actorDisplayName == "Ana")

        store.searchQuery = "expense"       // eventType match
        #expect(store.visibleEvents.count == 1)

        store.searchQuery = "   "           // whitespace-only is treated as empty
        #expect(store.visibleEvents.count == 3)
    }

    @Test("hasActiveFilter reflects category OR non-empty search")
    func hasActiveFilterFlag() async {
        let (store, _) = await makeStore(seed: [event("rule.created")])
        await store.refresh(groupId: groupId)
        #expect(store.hasActiveFilter == false)
        store.setCategory(.rules)
        #expect(store.hasActiveFilter)
        store.setCategory(nil)
        store.searchQuery = "foo"
        #expect(store.hasActiveFilter)
    }

    @Test("clear resets the filter + search state alongside events")
    func clearResetsFilterToo() async {
        let (store, _) = await makeStore(seed: [event("rule.created")])
        await store.refresh(groupId: groupId)
        store.setCategory(.rules)
        store.searchQuery = "x"
        store.clear()
        #expect(store.selectedCategory == nil)
        #expect(store.searchQuery.isEmpty)
    }

    @Test("HistoryCategory.members matcher catches mandate.* and contribution.* events")
    func membersCategoryCoversAdjacentPrimitives() {
        let mandate = GroupEvent(id: UUID(), groupId: groupId, eventType: "mandate.granted")
        let contribution = GroupEvent(id: UUID(), groupId: groupId, eventType: "contribution.logged")
        let invite = GroupEvent(id: UUID(), groupId: groupId, eventType: "invite.created")
        let unrelated = GroupEvent(id: UUID(), groupId: groupId, eventType: "rule.created")

        #expect(HistoryCategory.members.matches(mandate))
        #expect(HistoryCategory.members.matches(contribution))
        #expect(HistoryCategory.members.matches(invite))
        #expect(!HistoryCategory.members.matches(unrelated))
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
