import Foundation
import Testing
@testable import RuulCore

@Suite("GroupMandate domain")
struct GroupMandateTests {

    @Test("decodes the canonical row from group_mandates_active()")
    func decodesReadShape() throws {
        let mid = UUID(); let gid = UUID(); let repMid = UUID()
        let json = """
        {
          "mandate_id":                   "\(mid.uuidString)",
          "group_id":                     "\(gid.uuidString)",
          "principal_type":               "group",
          "principal_id":                 null,
          "representative_membership_id": "\(repMid.uuidString)",
          "representative_display_name":  "Ana López",
          "mandate_type":                 "represent",
          "scope":                        {},
          "status":                       "active",
          "starts_at":                    null,
          "ends_at":                      null,
          "source_decision_id":           null,
          "granted_by":                   null,
          "granted_by_display_name":      null,
          "created_at":                   null,
          "updated_at":                   null
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(GroupMandate.self, from: json)
        #expect(m.id == mid)
        #expect(m.groupId == gid)
        #expect(m.principalType == .group)
        #expect(m.principalId == nil)
        #expect(m.representativeMembershipId == repMid)
        #expect(m.representativeDisplayName == "Ana López")
        #expect(m.type == .represent)
        #expect(m.status == .active)
        #expect(m.isOpenEnded)
    }

    @Test("unknown enums fall back to safe defaults")
    func tolerantEnumFallback() throws {
        let json = """
        {
          "mandate_id":                   "\(UUID().uuidString)",
          "group_id":                     "\(UUID().uuidString)",
          "principal_type":               "future_concept",
          "representative_membership_id": "\(UUID().uuidString)",
          "mandate_type":                 "unicorn",
          "status":                       "wat"
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(GroupMandate.self, from: json)
        #expect(m.principalType == .group)
        #expect(m.type == .other)
        #expect(m.status == .active)
    }
}
