import Testing
import Foundation
import RuulCore
@testable import Tandas

/// Round-trip tests for `MockResourceLinkRepository`. Pins down the
/// `ResourceLinkRepository` protocol's idempotency + lifecycle shape so
/// the polymorphic Resource Detail's Connections section (which reads
/// from this repo) doesn't regress silently.
///
/// Per Plans/Active/CleanupAudit_2026-05-18 §08.9.1 — flagged as a Beta
/// blocker: "ResourceLinkRepository ships with zero tests despite being
/// load-bearing for the polymorphic detail page (`HierarchyReference.md`)".
@Suite("MockResourceLinkRepository")
struct MockResourceLinkRepositoryTests {

    // MARK: - listActiveUses

    @Test("listActiveUses returns only active uses links for the given event, newest first")
    func listActiveUsesFiltersAndSorts() async throws {
        let groupId = UUID()
        let eventA = UUID()
        let eventB = UUID()

        let earliest = ResourceLink(
            id: UUID(),
            groupId: groupId,
            fromResourceId: eventA,
            toResourceId: UUID(),
            linkKind: .uses,
            linkedAt: Date(timeIntervalSince1970: 1000)
        )
        let middle = ResourceLink(
            id: UUID(),
            groupId: groupId,
            fromResourceId: eventA,
            toResourceId: UUID(),
            linkKind: .uses,
            linkedAt: Date(timeIntervalSince1970: 2000),
            unlinkedAt: Date(timeIntervalSince1970: 2500)  // already unlinked
        )
        let newest = ResourceLink(
            id: UUID(),
            groupId: groupId,
            fromResourceId: eventA,
            toResourceId: UUID(),
            linkKind: .uses,
            linkedAt: Date(timeIntervalSince1970: 3000)
        )
        let otherEvent = ResourceLink(
            id: UUID(),
            groupId: groupId,
            fromResourceId: eventB,
            toResourceId: UUID(),
            linkKind: .uses,
            linkedAt: Date(timeIntervalSince1970: 4000)
        )

        let repo = MockResourceLinkRepository(seed: [earliest, middle, newest, otherEvent])
        let results = try await repo.listActiveUses(for: eventA)

        // middle is filtered out (unlinkedAt set → not active);
        // otherEvent is filtered out (wrong eventId);
        // newest sorts before earliest (descending by linkedAt).
        #expect(results.count == 2)
        #expect(results[0].id == newest.id)
        #expect(results[1].id == earliest.id)
    }

    @Test("listActiveUses returns empty when the event has no links")
    func listActiveUsesEmptyWhenNoMatches() async throws {
        let repo = MockResourceLinkRepository()
        let results = try await repo.listActiveUses(for: UUID())
        #expect(results.isEmpty)
    }

    // MARK: - link

    @Test("link adds a new active uses row and returns its id")
    func linkAddsRow() async throws {
        let repo = MockResourceLinkRepository()
        let eventId = UUID()
        let targetId = UUID()

        let linkId = try await repo.link(event: eventId, uses: targetId)

        let active = try await repo.listActiveUses(for: eventId)
        #expect(active.count == 1)
        #expect(active[0].id == linkId)
        #expect(active[0].toResourceId == targetId)
        #expect(active[0].linkKind == .uses)
        #expect(active[0].isActive)
    }

    @Test("link is idempotent: re-linking the same (event, target) returns the existing id")
    func linkIsIdempotent() async throws {
        let repo = MockResourceLinkRepository()
        let eventId = UUID()
        let targetId = UUID()

        let first  = try await repo.link(event: eventId, uses: targetId)
        let second = try await repo.link(event: eventId, uses: targetId)

        #expect(first == second)
        let active = try await repo.listActiveUses(for: eventId)
        #expect(active.count == 1)  // no duplicate row
    }

    @Test("link to a different target creates a new row, doesn't dedup across targets")
    func linkDifferentTargetsCreatesSeparateRows() async throws {
        let repo = MockResourceLinkRepository()
        let eventId = UUID()
        let targetA = UUID()
        let targetB = UUID()

        let idA = try await repo.link(event: eventId, uses: targetA)
        let idB = try await repo.link(event: eventId, uses: targetB)

        #expect(idA != idB)
        let active = try await repo.listActiveUses(for: eventId)
        #expect(active.count == 2)
        #expect(Set(active.map(\.toResourceId)) == Set([targetA, targetB]))
    }

    // MARK: - unlink

    @Test("unlink stamps unlinkedAt; the row is removed from listActiveUses")
    func unlinkRemovesFromActive() async throws {
        let repo = MockResourceLinkRepository()
        let eventId = UUID()
        let targetId = UUID()
        let linkId = try await repo.link(event: eventId, uses: targetId)

        try await repo.unlink(linkId)

        let active = try await repo.listActiveUses(for: eventId)
        #expect(active.isEmpty)
    }

    @Test("unlink is idempotent: a second call on the same link is a no-op")
    func unlinkIsIdempotent() async throws {
        let repo = MockResourceLinkRepository()
        let eventId = UUID()
        let linkId = try await repo.link(event: eventId, uses: UUID())

        try await repo.unlink(linkId)
        try await repo.unlink(linkId)  // must not throw

        let active = try await repo.listActiveUses(for: eventId)
        #expect(active.isEmpty)
    }

    @Test("unlink on an unknown link id is a no-op (doesn't throw)")
    func unlinkUnknownIdIsNoOp() async throws {
        let repo = MockResourceLinkRepository()
        try await repo.unlink(UUID())  // must not throw
    }

    @Test("re-linking after unlink creates a new active row (NOT the same id)")
    func relinkAfterUnlinkCreatesNew() async throws {
        let repo = MockResourceLinkRepository()
        let eventId = UUID()
        let targetId = UUID()

        let firstId = try await repo.link(event: eventId, uses: targetId)
        try await repo.unlink(firstId)
        let secondId = try await repo.link(event: eventId, uses: targetId)

        #expect(firstId != secondId)
        let active = try await repo.listActiveUses(for: eventId)
        #expect(active.count == 1)
        #expect(active[0].id == secondId)
    }

    // MARK: - error injection

    @Test("nextError is thrown once then cleared")
    func nextErrorIsOneShot() async throws {
        let repo = MockResourceLinkRepository()
        await repo.setNextError(.permissionDenied("denied"))

        do {
            _ = try await repo.listActiveUses(for: UUID())
            Issue.record("expected throw on first call after nextError set")
        } catch let err as ResourceLinkError {
            if case .permissionDenied(let m) = err {
                #expect(m == "denied")
            } else {
                Issue.record("expected .permissionDenied, got \(err)")
            }
        }

        // Second call should NOT throw — error was one-shot.
        let results = try await repo.listActiveUses(for: UUID())
        #expect(results.isEmpty)
    }
}

private extension MockResourceLinkRepository {
    /// Test-only setter so we can assign `nextError` through the actor
    /// boundary without making the property write public (it already is,
    /// but the actor isolation barrier means tests need an async hop).
    func setNextError(_ err: ResourceLinkError?) {
        self.nextError = err
    }
}
