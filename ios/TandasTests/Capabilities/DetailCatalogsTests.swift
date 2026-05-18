import Testing
import Foundation
import RuulCore
import RuulFeatures
@testable import Tandas

// MARK: - Fixtures

private enum Fixtures {
    static func group(id: UUID = .init()) -> Group {
        Group(
            id: id,
            name: "Cuates",
            inviteCode: "TEST1234",
            createdBy: UUID(),
            createdAt: .now
        )
    }

    static func resource(
        type: ResourceType,
        metadata: [String: JSONConfig] = [:],
        status: String = "active"
    ) -> ResourceRow {
        ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: type,
            status: status,
            metadata: .object(metadata),
            createdBy: UUID(),
            createdAt: .now,
            updatedAt: .now
        )
    }

    static func context(
        resource: ResourceRow,
        caps: Set<String>,
        memberDirectory: [UUID: MemberWithProfile] = [:]
    ) -> ResourceDetailContext {
        ResourceDetailContext(
            resource: resource,
            group: group(),
            currentUserId: UUID(),
            enabledCapabilities: caps,
            memberDirectory: memberDirectory,
            displayName: "Test"
        )
    }
}

// MARK: - CapabilitySectionCatalog

@Suite("CapabilitySectionCatalog")
@MainActor
struct CapabilitySectionCatalogTests {

    @Test("event with rsvp + check_in surfaces both sections, priority-sorted")
    func eventRSVPCheckIn() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .event),
            caps: ["rsvp", "check_in"]
        )
        let ids = CapabilitySectionCatalog.shared
            .sectionsFor(context: ctx)
            .map(\.id)
        #expect(ids.contains("rsvp"))
        #expect(ids.contains("check_in"))
        // rsvp priority 200, check_in priority 250 → rsvp first.
        let rsvpIdx = ids.firstIndex(of: "rsvp") ?? -1
        let checkInIdx = ids.firstIndex(of: "check_in") ?? -1
        #expect(rsvpIdx < checkInIdx, "priority sort violated: \(ids)")
    }

    @Test("asset with custody surfaces asset.custody, not space.*")
    func assetCustodyOnlyForAsset() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .asset),
            caps: ["custody"]
        )
        let ids = CapabilitySectionCatalog.shared
            .sectionsFor(context: ctx)
            .map(\.id)
        #expect(ids.contains("asset.custody"))
        #expect(!ids.contains("space.capacity"))
        #expect(!ids.contains("space.bookings"))
    }

    @Test("space with custody cap does NOT surface asset.custody")
    func customAssetSectionGatedByType() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .space),
            caps: ["custody"]
        )
        let ids = CapabilitySectionCatalog.shared
            .sectionsFor(context: ctx)
            .map(\.id)
        #expect(!ids.contains("asset.custody"),
                "asset.custody must gate on resourceType == .asset, got \(ids)")
    }

    @Test("fund surfaces fund.balance with no caps required")
    func fundBalanceShowsForFund() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .fund),
            caps: []
        )
        let ids = CapabilitySectionCatalog.shared
            .sectionsFor(context: ctx)
            .map(\.id)
        #expect(ids.contains("fund.balance"),
                "fund.balance should render for every fund regardless of caps")
    }

    @Test("non-event resource does NOT surface resource_links")
    func resourceLinksEventOnly() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .asset),
            caps: []
        )
        let ids = CapabilitySectionCatalog.shared
            .sectionsFor(context: ctx)
            .map(\.id)
        #expect(!ids.contains("resource_links"),
                "resource_links must gate on resourceType == .event")
    }

    @Test("event surfaces resource_links")
    func resourceLinksForEvent() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .event),
            caps: []
        )
        let ids = CapabilitySectionCatalog.shared
            .sectionsFor(context: ctx)
            .map(\.id)
        #expect(ids.contains("resource_links"))
    }

    @Test("sectionsFor returns priorities in ascending order")
    func prioritySortAscending() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .event),
            caps: ["rsvp", "check_in", "money", "rules", "activity", "description"]
        )
        let sections = CapabilitySectionCatalog.shared.sectionsFor(context: ctx)
        let priorities = sections.map(\.priority)
        #expect(priorities == priorities.sorted(),
                "sections must be priority-sorted ascending, got \(priorities)")
    }
}

// MARK: - ResourceInfoRegistry

@Suite("ResourceInfoRegistry")
@MainActor
struct ResourceInfoRegistryTests {

    @Test("fund with currency + target produces Moneda + Meta rows")
    func fundRows() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(
                type: .fund,
                metadata: [
                    "currency": .string("MXN"),
                    "target_amount_cents": .int(500_000),
                ]
            ),
            caps: []
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        let labels = rows.map(\.label)
        #expect(labels.contains("Moneda"))
        #expect(labels.contains("Meta"))
        let moneda = rows.first { $0.label == "Moneda" }?.value
        #expect(moneda == "MXN")
    }

    @Test("fund with locked_at surfaces Estado: Bloqueado row")
    func fundLockedRow() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(
                type: .fund,
                metadata: [
                    "locked_at": .string("2026-05-18T00:00:00Z"),
                    "locked_reason": .string("audit"),
                ]
            ),
            caps: []
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        let estado = rows.first { $0.label == "Estado" }?.value
        #expect(estado == "Bloqueado (audit)")
    }

    @Test("space with location_name produces Dirección row")
    func spaceLocationRow() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(
                type: .space,
                metadata: [
                    "location_name": .string("Av. Reforma 123"),
                    "capacity": .int(30),
                ]
            ),
            caps: []
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        #expect(rows.contains { $0.label == "Dirección" && $0.value == "Av. Reforma 123" })
        #expect(rows.contains { $0.label == "Capacidad" && $0.value == "30" })
    }

    @Test("right with holder_user_id resolves Titular from member directory")
    func rightTitularRow() {
        let holderUid = UUID()
        let member = MemberWithProfile(
            member: Member(
                id: UUID(),
                groupId: UUID(),
                userId: holderUid,
                joinedAt: .now
            ),
            profile: Profile(
                id: holderUid,
                displayName: "Isaac",
                avatarUrl: nil,
                phone: nil
            )
        )
        let ctx = Fixtures.context(
            resource: Fixtures.resource(
                type: .right,
                metadata: ["holder_user_id": .string(holderUid.uuidString)]
            ),
            caps: [],
            memberDirectory: [holderUid: member]
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        #expect(rows.contains { $0.label == "Titular" && $0.value == "Isaac" })
    }

    @Test("right with revoked status surfaces Estado: Revocado")
    func rightRevokedStatus() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .right, status: "revoked"),
            caps: []
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        #expect(rows.contains { $0.label == "Estado" && $0.value == "Revocado" })
    }

    @Test("right with active status does NOT surface Estado row")
    func rightActiveStatusHidden() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .right, status: "active"),
            caps: []
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        #expect(!rows.contains { $0.label == "Estado" },
                "active is the implicit default; no Estado row expected")
    }

    @Test("event returns empty rows (no provider registered)")
    func eventNoProvider() {
        let ctx = Fixtures.context(
            resource: Fixtures.resource(type: .event),
            caps: []
        )
        let rows = ResourceInfoRegistry.shared.rows(for: ctx)
        #expect(rows.isEmpty)
    }
}

// MARK: - ResourceRow.rightHolderMemberId

@Suite("ResourceRow.rightHolderMemberId")
struct ResourceRowRightHolderTests {

    @Test("returns nil for non-right resource even when metadata has the key")
    func nonRightReturnsNil() {
        let assetMemberId = UUID()
        let asset = Fixtures.resource(
            type: .asset,
            metadata: ["holder_member_id": .string(assetMemberId.uuidString)]
        )
        #expect(asset.rightHolderMemberId == nil)
    }

    @Test("returns parsed UUID for right with valid metadata")
    func rightWithHolderReturnsId() {
        let memberId = UUID()
        let right = Fixtures.resource(
            type: .right,
            metadata: ["holder_member_id": .string(memberId.uuidString)]
        )
        #expect(right.rightHolderMemberId == memberId)
    }

    @Test("returns nil when metadata key missing")
    func rightWithoutMetadataReturnsNil() {
        let right = Fixtures.resource(type: .right, metadata: [:])
        #expect(right.rightHolderMemberId == nil)
    }
}
