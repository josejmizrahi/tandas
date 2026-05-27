import Foundation
import Testing
@testable import RuulCore

@Suite("GroupEvent domain")
struct GroupEventTests {

    @Test("decodes the canonical row from group_events_recent()")
    func decodesReadShape() throws {
        let eid = UUID(); let gid = UUID(); let uid = UUID(); let entId = UUID()
        let json = """
        {
          "event_uuid":          "\(eid.uuidString)",
          "group_id":            "\(gid.uuidString)",
          "actor_user_id":       "\(uid.uuidString)",
          "actor_display_name":  "Ana López",
          "event_type":          "sanction.issued",
          "entity_kind":         "sanction",
          "entity_id":           "\(entId.uuidString)",
          "summary":             "Multa por faltar a la cena.",
          "payload":             {},
          "occurred_at":         null
        }
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(GroupEvent.self, from: json)
        #expect(e.id == eid)
        #expect(e.groupId == gid)
        #expect(e.actorUserId == uid)
        #expect(e.actorDisplayName == "Ana López")
        #expect(e.eventType == "sanction.issued")
        #expect(e.entityKind == "sanction")
        #expect(e.entityId == entId)
        #expect(e.summary == "Multa por faltar a la cena.")
    }

    @Test("optional fields decode to nil when null")
    func decodesNulls() throws {
        let json = """
        {
          "event_uuid":   "\(UUID().uuidString)",
          "group_id":     "\(UUID().uuidString)",
          "actor_user_id": null,
          "actor_display_name": null,
          "event_type":   "system.bootstrap",
          "entity_kind":  null,
          "entity_id":    null,
          "summary":      null,
          "payload":      {},
          "occurred_at":  null
        }
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(GroupEvent.self, from: json)
        #expect(e.actorUserId == nil)
        #expect(e.summary == nil)
        #expect(e.entityKind == nil)
        #expect(e.eventType == "system.bootstrap")
    }

    @Test("systemImageName maps curated event_type keys + falls back for unknown")
    func systemImageMapping() {
        let known = [
            "sanction.issued", "dispute.opened", "decision_rules.set",
            "purpose.set", "rule.created", "rule.archived", "resource.created",
            "settlement.recorded", "member.invited", "member.left"
        ]
        for key in known {
            let e = GroupEvent(id: UUID(), groupId: UUID(), eventType: key)
            // Each canonical key maps to a non-default icon.
            #expect(e.systemImageName != "circle.fill", "expected curated icon for \(key)")
        }
        let unknown = GroupEvent(id: UUID(), groupId: UUID(), eventType: "future.event")
        #expect(unknown.systemImageName == "circle.fill")
    }
}
