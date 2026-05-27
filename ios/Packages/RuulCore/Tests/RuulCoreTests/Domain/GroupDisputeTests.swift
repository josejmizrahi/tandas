import Foundation
import Testing
@testable import RuulCore

@Suite("GroupDispute domain")
struct GroupDisputeTests {

    @Test("decodes the canonical row from group_disputes_active()")
    func decodesReadShape() throws {
        let did = UUID(); let gid = UUID(); let oid = UUID(); let rid = UUID(); let sid = UUID()
        let json = """
        {
          "dispute_id":                "\(did.uuidString)",
          "group_id":                  "\(gid.uuidString)",
          "opened_by_membership_id":   "\(oid.uuidString)",
          "opened_by_display_name":    "Ana López",
          "respondent_membership_id":  "\(rid.uuidString)",
          "respondent_display_name":   "Mateo",
          "subject_kind":              "sanction",
          "subject_id":                "\(sid.uuidString)",
          "title":                     "Apela la multa del viernes",
          "description":               "No estuve en la cena.",
          "status":                    "in_review",
          "mediator_membership_id":    null,
          "mediator_display_name":     null,
          "resolution_method":         null,
          "resolution":                null,
          "opened_at":                 null,
          "resolved_at":               null
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(GroupDispute.self, from: json)
        #expect(d.id == did)
        #expect(d.subjectKind == .sanction)
        #expect(d.subjectId == sid)
        #expect(d.status == .inReview)
        #expect(d.openedByDisplayName == "Ana López")
        #expect(d.isSanctionDispute)
        #expect(d.status.isOpen)
    }

    @Test("unknown enum values fall back to safe defaults")
    func enumFallbacks() throws {
        let json = """
        {
          "dispute_id":    "\(UUID().uuidString)",
          "group_id":      "\(UUID().uuidString)",
          "subject_kind":  "future_kind",
          "title":         "X",
          "status":        "future_status"
        }
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(GroupDispute.self, from: json)
        #expect(d.subjectKind == .other)
        #expect(d.status == .open)
    }

    @Test("status.isOpen reflects open/in_review/mediation/escalated")
    func statusIsOpen() {
        #expect(DisputeStatus.open.isOpen)
        #expect(DisputeStatus.inReview.isOpen)
        #expect(DisputeStatus.mediation.isOpen)
        #expect(DisputeStatus.escalated.isOpen)
        #expect(DisputeStatus.resolved.isOpen == false)
        #expect(DisputeStatus.dismissed.isOpen == false)
        #expect(DisputeStatus.closed.isOpen == false)
    }

    @Test("subject_kind enum covers the canonical CHECK constraint values")
    func subjectKindCoverage() {
        let values = Set(DisputeSubjectKind.allCases.map(\.rawValue))
        #expect(values == ["sanction", "rule", "resource", "member", "other"])
    }
}
