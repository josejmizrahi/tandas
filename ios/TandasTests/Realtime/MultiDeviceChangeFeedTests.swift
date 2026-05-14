import Testing
import Foundation
import RuulCore
import RuulFeatures
@testable import Tandas

/// Beta 1 W3 E-3.1 — regression coverage for the change-feed → coordinator wire.
///
/// The Live feed (Supabase Realtime) is integration-tested in production
/// against the Postgres publication created by mig 00161. These suites
/// pin the *contract* the coordinators rely on:
///   1. `MockMultiDeviceChangeFeed.inject(_:)` yields through `changes`.
///   2. A coordinator that subscribes to `.userAction` invocations
///      triggers its own `refresh()` exactly once per change.
///   3. Filters fire only for the matching `Change.Table` — a `.vote`
///      kick does not refresh an inbox.
@Suite("MultiDeviceChangeFeed contract + coordinator wiring")
@MainActor
struct MultiDeviceChangeFeedTests {

    private func sampleAction(userId: UUID, groupId: UUID) -> UserAction {
        UserAction(
            userId: userId,
            groupId: groupId,
            actionType: .finePending,
            referenceId: UUID(),
            title: "Pending"
        )
    }

    @Test("MockMultiDeviceChangeFeed yields injected changes")
    func mockYieldsInjectedChanges() async {
        let feed = MockMultiDeviceChangeFeed()
        let id = UUID()

        Task {
            await feed.inject(MultiDeviceChange(table: .userAction, recordId: id))
        }

        // Read one change from the stream.
        var received: MultiDeviceChange?
        for await change in feed.changes {
            received = change
            break
        }

        #expect(received?.table == .userAction)
        #expect(received?.recordId == id)
    }

    @Test("InboxCoordinator refreshes when a .userAction change fires")
    func userActionChangeTriggersInboxRefresh() async throws {
        let userId = UUID()
        let groupId = UUID()
        let feed = MockMultiDeviceChangeFeed()
        let repo = MockUserActionRepository(seed: [
            sampleAction(userId: userId, groupId: groupId)
        ])
        let coord = InboxCoordinator(
            userId: userId,
            groupId: nil,
            userActionRepo: repo,
            groupsRepo: nil,
            changeFeed: feed
        )

        #expect(coord.actions.isEmpty)

        // Trigger the kick. The Task spawned in init iterates `changes`
        // and calls refresh(); we wait briefly for it to land.
        await feed.inject(MultiDeviceChange(table: .userAction, recordId: UUID()))

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        #expect(coord.actions.count == 1)
    }

    @Test("InboxCoordinator ignores changes of other tables")
    func otherTableChangesAreNoOp() async throws {
        let userId = UUID()
        let groupId = UUID()
        let feed = MockMultiDeviceChangeFeed()
        let repo = MockUserActionRepository(seed: [
            sampleAction(userId: userId, groupId: groupId)
        ])
        let coord = InboxCoordinator(
            userId: userId,
            groupId: nil,
            userActionRepo: repo,
            groupsRepo: nil,
            changeFeed: feed
        )

        await feed.inject(MultiDeviceChange(table: .vote, recordId: UUID()))
        await feed.inject(MultiDeviceChange(table: .fine, recordId: UUID()))
        await feed.inject(MultiDeviceChange(table: .voteCast, recordId: UUID()))

        try await Task.sleep(nanoseconds: 100_000_000)

        // Coordinator never refreshed → actions remains untouched (empty,
        // because refresh() is the only path that loads them).
        #expect(coord.actions.isEmpty)
    }
}
