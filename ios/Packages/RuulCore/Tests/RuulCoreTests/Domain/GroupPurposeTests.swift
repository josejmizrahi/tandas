import Foundation
import Testing
@testable import RuulCore

@Suite("GroupPurpose domain")
struct GroupPurposeTests {

    @Test("displayOrder is declared → operative → emotional")
    func displayOrder() {
        #expect(GroupPurposeKind.displayOrder == [.declared, .operative, .emotional])
    }

    @Test("decodes the read RPC shape (purpose_id key)")
    func decodesReadShape() throws {
        let pid = UUID(); let gid = UUID()
        let json = """
        {
          "purpose_id": "\(pid.uuidString)",
          "group_id":   "\(gid.uuidString)",
          "kind":       "declared",
          "body":       "Jugar poker los viernes",
          "visibility": "members",
          "status":     "active",
          "created_by": null,
          "created_at": null,
          "updated_at": null
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(GroupPurpose.self, from: json)
        #expect(p.id == pid)
        #expect(p.groupId == gid)
        #expect(p.kind == .declared)
        #expect(p.body == "Jugar poker los viernes")
        #expect(p.visibility == .members)
        #expect(p.status == "active")
    }

    @Test("decodes the set RPC shape (id key)")
    func decodesSetShape() throws {
        let pid = UUID(); let gid = UUID()
        let json = """
        {
          "id":         "\(pid.uuidString)",
          "group_id":   "\(gid.uuidString)",
          "kind":       "emotional",
          "body":       "Hermanos",
          "visibility": "private",
          "status":     "active",
          "created_by": null,
          "created_at": null,
          "updated_at": null
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(GroupPurpose.self, from: json)
        #expect(p.id == pid)
        #expect(p.kind == .emotional)
        #expect(p.visibility == .private)
    }

    @Test("unknown enums fall back to safe defaults")
    func enumFallbacks() throws {
        let json = """
        {
          "purpose_id": "\(UUID().uuidString)",
          "group_id":   "\(UUID().uuidString)",
          "kind":       "future_kind",
          "body":       "?",
          "visibility": "future_vis",
          "status":     "active"
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(GroupPurpose.self, from: json)
        #expect(p.kind == .declared)
        #expect(p.visibility == .members)
    }
}
