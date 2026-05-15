import Testing
import Foundation
import RuulCore
@testable import Tandas

// MARK: - QuickFacts tests
// Cover subtitle tests are folded in at the bottom of this file
// (they share the same makeResource helper, 6+6 tests total here).

@Suite("CapabilityResolver.quickFacts")
struct CapabilityResolverQuickFactsTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)

    // MARK: - Helpers

    private func makeResource(
        type: ResourceType,
        status: String = "scheduled",
        metadata: JSONConfig = .empty
    ) -> ResourceRow {
        ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: type,
            status: status,
            metadata: metadata,
            createdBy: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func makeGroup(activeModules: [String] = ["basic_fines", "rsvp", "check_in"]) -> Group {
        Group(
            id: UUID(),
            name: "Test Group",
            description: nil,
            inviteCode: "TST01",
            coverImageName: nil,
            baseTemplate: "recurring_dinner",
            activeModules: activeModules,
            governance: nil,
            settings: nil,
            category: .socialRecurring,
            initials: "TG",
            avatarUrl: nil,
            createdBy: UUID(),
            createdAt: Date()
        )
    }

    private static let sampleISO = "2026-06-15T20:00:00Z"

    private static func eventMetadata(
        includeLocation: Bool = true,
        includeCapacity: Bool = true
    ) -> JSONConfig {
        var dict: [String: JSONConfig] = [
            "starts_at": .string(sampleISO)
        ]
        if includeLocation { dict["location"] = .string("Casa de Ana") }
        if includeCapacity {
            dict["capacity"] = .int(12)
            dict["attendee_count"] = .int(8)
        }
        return .object(dict)
    }

    // MARK: - Test 1: event with all capabilities → 4 facts

    @Test("event + scheduling + location + rsvp → date, time, location, capacity facts")
    func eventAllCapabilities() {
        let resource = makeResource(type: .event, metadata: Self.eventMetadata())
        let facts = resolver.quickFacts(
            for: resource,
            in: makeGroup(),
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(facts.count == 4)
        #expect(facts.contains { $0.kind == .date })
        #expect(facts.contains { $0.kind == .time })
        #expect(facts.contains { $0.kind == .location })
        #expect(facts.contains { $0.kind == .capacity })
    }

    // MARK: - Test 2: event missing starts_at → no date/time facts

    @Test("event without starts_at → no date or time fact")
    func eventMissingStartsAt() {
        let meta: JSONConfig = .object([
            "location": .string("Parque"),
            "capacity": .int(10),
            "attendee_count": .int(3)
        ])
        let resource = makeResource(type: .event, metadata: meta)
        let facts = resolver.quickFacts(
            for: resource,
            in: makeGroup(),
            enabledCapabilities: ["scheduling", "rsvp"]
        )
        #expect(!facts.contains { $0.kind == .date })
        #expect(!facts.contains { $0.kind == .time })
        // location + capacity should still appear
        #expect(facts.contains { $0.kind == .location })
        #expect(facts.contains { $0.kind == .capacity })
    }

    // MARK: - Test 3: fund with ledger → balance + progress facts

    @Test("fund + ledger capability → balance and progress facts")
    func fundWithLedger() {
        let meta: JSONConfig = .object([
            "balance_display": .string("$4,500"),
            "progress_display": .string("45%")
        ])
        let resource = makeResource(type: .fund, metadata: meta)
        let facts = resolver.quickFacts(
            for: resource,
            in: makeGroup(),
            enabledCapabilities: ["ledger"]
        )
        #expect(facts.count == 2)
        #expect(facts.contains { $0.kind == .balance })
        #expect(facts.contains { $0.kind == .progress })
    }

    // MARK: - Test 4: asset with status + location → 2 facts

    @Test("asset with status_display and location → status and location facts")
    func assetStatusAndLocation() {
        let meta: JSONConfig = .object([
            "status_display": .string("Disponible"),
            "location": .string("Bodega 3")
        ])
        let resource = makeResource(type: .asset, metadata: meta)
        let facts = resolver.quickFacts(
            for: resource,
            in: makeGroup(),
            enabledCapabilities: []
        )
        #expect(facts.count == 2)
        #expect(facts.contains { $0.kind == .status })
        #expect(facts.contains { $0.kind == .location })
    }

    // MARK: - Test 5: unknown type → empty

    @Test("unknown resource type → empty facts")
    func unknownTypeEmpty() {
        let resource = makeResource(type: .unknown("other"))
        let facts = resolver.quickFacts(
            for: resource,
            in: makeGroup(),
            enabledCapabilities: ["scheduling", "rsvp", "ledger"]
        )
        #expect(facts.isEmpty)
    }

    // MARK: - Test 6: event without rsvp capability → no capacity fact

    @Test("event without rsvp capability → capacity fact absent")
    func eventNoRsvpCapacity() {
        let resource = makeResource(type: .event, metadata: Self.eventMetadata(includeCapacity: true))
        let facts = resolver.quickFacts(
            for: resource,
            in: makeGroup(),
            enabledCapabilities: ["scheduling"]   // rsvp intentionally absent
        )
        #expect(!facts.contains { $0.kind == .capacity })
        // date + time should still appear
        #expect(facts.contains { $0.kind == .date })
        #expect(facts.contains { $0.kind == .time })
    }
}

// MARK: - CoverSubtitle tests (folded here, same makeResource helper)

@Suite("CapabilityResolver.coverSubtitle")
struct CapabilityResolverCoverSubtitleTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)

    private func makeResource(
        type: ResourceType,
        metadata: JSONConfig = .empty
    ) -> ResourceRow {
        ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: type,
            status: "scheduled",
            metadata: metadata,
            createdBy: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func makeGroup() -> Group {
        Group(
            id: UUID(),
            name: "Test",
            description: nil,
            inviteCode: "TST02",
            coverImageName: nil,
            baseTemplate: "recurring_dinner",
            activeModules: ["rsvp"],
            governance: nil,
            settings: nil,
            category: .socialRecurring,
            initials: "T",
            avatarUrl: nil,
            createdBy: UUID(),
            createdAt: Date()
        )
    }

    private func makeMember(id: UUID, displayName: String) -> MemberWithProfile {
        let member = Member(
            id: id,
            groupId: UUID(),
            userId: UUID(),
            displayNameOverride: displayName,
            joinedAt: Date()
        )
        return MemberWithProfile(member: member, profile: nil)
    }

    // MARK: - Test 7: event with host + attendees → "Hosted by X · N going"

    @Test("event with host and attendees → composite subtitle")
    func eventHostAndAttendees() {
        let hostId = UUID()
        let meta: JSONConfig = .object([
            "host_id": .string(hostId.uuidString),
            "attendee_count": .int(5)
        ])
        let resource = makeResource(type: .event, metadata: meta)
        let directory: [UUID: MemberWithProfile] = [hostId: makeMember(id: hostId, displayName: "Daniel")]
        let subtitle = resolver.coverSubtitle(
            for: resource,
            in: makeGroup(),
            memberDirectory: directory,
            enabledCapabilities: ["rsvp"]
        )
        #expect(subtitle == "Hosted by Daniel · 5 going")
    }

    // MARK: - Test 8: event host not in directory → only attendee count

    @Test("event host missing from directory → shows only attendee count")
    func eventHostMissing() {
        let meta: JSONConfig = .object([
            "host_id": .string(UUID().uuidString),
            "attendee_count": .int(3)
        ])
        let resource = makeResource(type: .event, metadata: meta)
        let subtitle = resolver.coverSubtitle(
            for: resource,
            in: makeGroup(),
            memberDirectory: [:],
            enabledCapabilities: ["rsvp"]
        )
        #expect(subtitle == "3 going")
    }

    // MARK: - Test 9: fund with balance + goal → "X of Y raised"

    @Test("fund with balance and goal → raised subtitle")
    func fundRaisedSubtitle() {
        let meta: JSONConfig = .object([
            "balance_display": .string("$4,500"),
            "goal_display": .string("$10,000")
        ])
        let resource = makeResource(type: .fund, metadata: meta)
        let subtitle = resolver.coverSubtitle(
            for: resource,
            in: makeGroup(),
            memberDirectory: [:],
            enabledCapabilities: []
        )
        #expect(subtitle == "$4,500 of $10,000 raised")
    }

    // MARK: - Test 10: asset with custodian → "Custodian: X"

    @Test("asset with custodian in directory → custodian subtitle")
    func assetCustodianSubtitle() {
        let custodianId = UUID()
        let meta: JSONConfig = .object([
            "custodian_id": .string(custodianId.uuidString)
        ])
        let resource = makeResource(type: .asset, metadata: meta)
        let directory: [UUID: MemberWithProfile] = [custodianId: makeMember(id: custodianId, displayName: "Lynda")]
        let subtitle = resolver.coverSubtitle(
            for: resource,
            in: makeGroup(),
            memberDirectory: directory,
            enabledCapabilities: []
        )
        #expect(subtitle == "Custodian: Lynda")
    }

    // MARK: - Test 11: unknown type → nil subtitle

    @Test("unknown type → nil subtitle")
    func unknownTypeNilSubtitle() {
        let resource = makeResource(type: .unknown("other"))
        let subtitle = resolver.coverSubtitle(
            for: resource,
            in: makeGroup(),
            memberDirectory: [:],
            enabledCapabilities: []
        )
        #expect(subtitle == nil)
    }

    // MARK: - Test 12: event with zero attendees + no host → nil subtitle

    @Test("event with zero attendees and no host → nil subtitle")
    func eventZeroAttendeesNoHost() {
        let meta: JSONConfig = .object([
            "attendee_count": .int(0)
        ])
        let resource = makeResource(type: .event, metadata: meta)
        let subtitle = resolver.coverSubtitle(
            for: resource,
            in: makeGroup(),
            memberDirectory: [:],
            enabledCapabilities: ["rsvp"]
        )
        #expect(subtitle == nil)
    }
}
