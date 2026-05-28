import Foundation
import Testing
@testable import RuulCore

@Suite("GroupDispute detail + events")
struct GroupDisputeDetailTests {

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    @Test("GroupDisputeDetail decodes the wire row + escalated decision link")
    func decodesDetail() throws {
        let did = UUID(); let gid = UUID(); let escalated = UUID()
        let json = """
        {
          "dispute_id":                "\(did.uuidString)",
          "group_id":                  "\(gid.uuidString)",
          "opened_by_membership_id":   null,
          "opened_by_display_name":    "Ana",
          "respondent_membership_id":  null,
          "respondent_display_name":   null,
          "mediator_membership_id":    null,
          "mediator_display_name":     "Mateo",
          "subject_kind":              "rule",
          "subject_id":                null,
          "title":                     "Sobre la regla X",
          "description":               "Texto",
          "status":                    "escalated",
          "resolution_method":         null,
          "resolution":                null,
          "escalated_decision_id":     "\(escalated.uuidString)",
          "opened_at":                 null,
          "resolved_at":               null,
          "metadata":                  {},
          "event_count":               4
        }
        """.data(using: .utf8)!
        let det = try makeDecoder().decode(GroupDisputeDetail.self, from: json)
        #expect(det.id == did)
        #expect(det.groupId == gid)
        #expect(det.subjectKind == .rule)
        #expect(det.status == .escalated)
        #expect(det.escalatedDecisionId == escalated)
        #expect(det.eventCount == 4)
        #expect(det.openedByDisplayName == "Ana")
        #expect(det.mediatorDisplayName == "Mateo")
    }

    @Test("GroupDisputeEvent decodes timeline row + falls back to .other on unknown type")
    func decodesEvent() throws {
        let did = UUID(); let eid = UUID()
        let json = """
        {
          "event_id":              "\(eid.uuidString)",
          "dispute_id":            "\(did.uuidString)",
          "actor_membership_id":   null,
          "actor_display_name":    "Jose",
          "event_type":            "evidence_added",
          "body":                  "La foto",
          "metadata":              {},
          "created_at":            null
        }
        """.data(using: .utf8)!
        let evt = try makeDecoder().decode(GroupDisputeEvent.self, from: json)
        #expect(evt.id == eid)
        #expect(evt.eventType == .evidenceAdded)
        #expect(evt.body == "La foto")

        let unknown = """
        {
          "event_id":     "\(UUID().uuidString)",
          "dispute_id":   "\(did.uuidString)",
          "event_type":   "future_kind"
        }
        """.data(using: .utf8)!
        let evt2 = try makeDecoder().decode(GroupDisputeEvent.self, from: unknown)
        #expect(evt2.eventType == .other)
    }

    @Test("DisputeEventType.userSelectable hides backend-only types")
    func userSelectableExcludesBackendOnly() {
        let selectable = DisputeEventType.userSelectable
        #expect(selectable.contains(.comment))
        #expect(selectable.contains(.evidenceAdded))
        #expect(selectable.contains(.mediationNote))
        #expect(selectable.contains(.other))
        #expect(selectable.contains(.statusChange) == false)
        #expect(selectable.contains(.resolution) == false)
        #expect(selectable.contains(.escalation) == false)
    }
}
