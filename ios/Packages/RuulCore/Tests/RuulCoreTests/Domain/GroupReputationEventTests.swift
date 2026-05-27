import Foundation
import Testing
@testable import RuulCore

@Suite("GroupReputationEvent domain")
struct GroupReputationEventTests {

    @Test("decodes the canonical event row returned by member_reputation_events()")
    func decodesReadShape() throws {
        let eid = UUID(); let gid = UUID(); let mid = UUID()
        let json = """
        {
          "event_id":              "\(eid.uuidString)",
          "group_id":              "\(gid.uuidString)",
          "subject_membership_id": "\(mid.uuidString)",
          "actor_membership_id":   null,
          "reputation_type":       "commitment_kept",
          "reason":                "Llegó a la cena con la cuota lista.",
          "evidence_entity_kind":  "settlement",
          "evidence_entity_id":    null,
          "visibility":            "members",
          "status":                "active",
          "metadata":              {},
          "occurred_at":           null,
          "created_at":            null
        }
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(GroupReputationEvent.self, from: json)
        #expect(e.id == eid)
        #expect(e.groupId == gid)
        #expect(e.subjectMembershipId == mid)
        #expect(e.kind == .commitmentKept)
        #expect(e.reason == "Llegó a la cena con la cuota lista.")
        #expect(e.evidenceEntityKind == "settlement")
        #expect(e.visibility == .members)
    }

    @Test("decodes the write-row shape (id key)")
    func decodesWriteShape() throws {
        let eid = UUID(); let gid = UUID(); let mid = UUID()
        let json = """
        {
          "id":                    "\(eid.uuidString)",
          "group_id":              "\(gid.uuidString)",
          "subject_membership_id": "\(mid.uuidString)",
          "reputation_type":       "rule_violation",
          "visibility":            "private",
          "status":                "active"
        }
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(GroupReputationEvent.self, from: json)
        #expect(e.id == eid)
        #expect(e.kind == .ruleViolation)
        #expect(e.visibility == .private)
    }

    @Test("unknown enum values fall back to safe defaults")
    func enumFallbacks() throws {
        let json = """
        {
          "event_id":              "\(UUID().uuidString)",
          "group_id":              "\(UUID().uuidString)",
          "subject_membership_id": "\(UUID().uuidString)",
          "reputation_type":       "future_kind",
          "visibility":            "future_vis",
          "status":                "active"
        }
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(GroupReputationEvent.self, from: json)
        #expect(e.kind == .other)
        #expect(e.visibility == .members)
    }

    @Test("when prefers occurred_at, falls back to created_at, else nil")
    func whenPrecedence() {
        let occurred = Date(timeIntervalSince1970: 1_700_000_000)
        let created  = Date(timeIntervalSince1970: 1_800_000_000)
        let both = GroupReputationEvent(
            id: UUID(), groupId: UUID(), subjectMembershipId: UUID(),
            kind: .careShown, occurredAt: occurred, createdAt: created
        )
        #expect(both.when == occurred)

        let createdOnly = GroupReputationEvent(
            id: UUID(), groupId: UUID(), subjectMembershipId: UUID(),
            kind: .careShown, occurredAt: nil, createdAt: created
        )
        #expect(createdOnly.when == created)

        let neither = GroupReputationEvent(
            id: UUID(), groupId: UUID(), subjectMembershipId: UUID(),
            kind: .careShown, occurredAt: nil, createdAt: nil
        )
        #expect(neither.when == nil)
    }
}
