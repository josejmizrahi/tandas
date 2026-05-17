import Testing
import Foundation
import RuulCore

/// Covers the polymorphic methods the mock implements. The Live repo
/// is exercised end-to-end via the manual smoke tests captured in
/// Plans/Active/ResourceLinks.md §9; these unit tests just lock the
/// semantics so future refactors of the mock don't drift.
@Suite("MockResourceLinkRepository")
struct MockResourceLinkRepositoryTests {

    private func makeRow(
        from: UUID,
        to: UUID,
        kind: LinkKind = .uses,
        active: Bool = true
    ) -> ResourceLink {
        ResourceLink(
            id: UUID(),
            groupId: UUID(),
            fromResourceId: from,
            toResourceId: to,
            linkKind: kind,
            linkedAt: Date(),
            linkedBy: nil,
            unlinkedAt: active ? nil : Date(),
            unlinkedBy: nil
        )
    }

    @Test("link creates a new row when no active link exists for the tuple")
    func linkCreatesNewRow() async throws {
        let repo = MockResourceLinkRepository()
        let from = UUID()
        let to = UUID()
        let id = try await repo.link(from: from, to: to, kind: .owns)
        let (incoming, outgoing) = try await repo.linksFor(resource: from)
        #expect(incoming.isEmpty)
        #expect(outgoing.count == 1)
        #expect(outgoing.first?.id == id)
        #expect(outgoing.first?.linkKind == .owns)
    }

    @Test("link is idempotent — same tuple returns existing id")
    func linkIdempotent() async throws {
        let repo = MockResourceLinkRepository()
        let from = UUID()
        let to = UUID()
        let id1 = try await repo.link(from: from, to: to, kind: .uses)
        let id2 = try await repo.link(from: from, to: to, kind: .uses)
        #expect(id1 == id2)
    }

    @Test("link with different kind creates a separate row")
    func linkDifferentKindsCoexist() async throws {
        let repo = MockResourceLinkRepository()
        let from = UUID()
        let to = UUID()
        _ = try await repo.link(from: from, to: to, kind: .uses)
        _ = try await repo.link(from: from, to: to, kind: .funds)
        let (_, outgoing) = try await repo.linksFor(resource: from)
        let kinds = Set(outgoing.map(\.linkKind))
        #expect(kinds == [.uses, .funds])
    }

    @Test("unlink marks the matching active row inactive — silent no-op when absent")
    func unlinkSemantics() async throws {
        let repo = MockResourceLinkRepository()
        let from = UUID()
        let to = UUID()
        _ = try await repo.link(from: from, to: to, kind: .governs)
        try await repo.unlink(from: from, to: to, kind: .governs)
        let (_, outgoing) = try await repo.linksFor(resource: from)
        #expect(outgoing.isEmpty, "active list should be empty after unlink")

        // No-op when called again
        try await repo.unlink(from: from, to: to, kind: .governs)
    }

    @Test("linksFor splits incoming + outgoing by direction")
    func linksForSplitsDirection() async throws {
        let repo = MockResourceLinkRepository()
        let me = UUID()
        let other1 = UUID()
        let other2 = UUID()
        _ = try await repo.link(from: me, to: other1, kind: .owns)         // outgoing
        _ = try await repo.link(from: other2, to: me, kind: .governs)      // incoming
        let (incoming, outgoing) = try await repo.linksFor(resource: me)
        #expect(outgoing.count == 1)
        #expect(outgoing.first?.toResourceId == other1)
        #expect(incoming.count == 1)
        #expect(incoming.first?.fromResourceId == other2)
    }

    @Test("legacy link(event:uses:) routes through the polymorphic path")
    func legacyLinkWorks() async throws {
        let repo = MockResourceLinkRepository()
        let event = UUID()
        let target = UUID()
        let id = try await repo.link(event: event, uses: target)
        let (_, outgoing) = try await repo.linksFor(resource: event)
        #expect(outgoing.first?.id == id)
        #expect(outgoing.first?.linkKind == .uses)
    }

    @Test("legacy listActiveUses surfaces only 'uses' outgoing edges")
    func legacyListActiveUsesFilters() async throws {
        let repo = MockResourceLinkRepository()
        let event = UUID()
        let target = UUID()
        let fund = UUID()
        _ = try await repo.link(from: event, to: target, kind: .uses)
        _ = try await repo.link(from: event, to: fund, kind: .funds)
        let usesRows = try await repo.listActiveUses(for: event)
        #expect(usesRows.count == 1)
        #expect(usesRows.first?.linkKind == .uses)
    }
}
