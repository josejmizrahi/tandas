import Foundation
import Testing
@testable import RuulCore

@Suite("GroupResource domain")
struct GroupResourceTests {

    @Test("decodes a row from group_resources_active")
    func decodesReadShape() throws {
        let rid = UUID(); let gid = UUID()
        let json = """
        {
          "resource_id":             "\(rid.uuidString)",
          "group_id":                "\(gid.uuidString)",
          "resource_type":           "fund",
          "name":                    "Fondo del viaje",
          "description":             "Pagar gasolina",
          "status":                  "active",
          "visibility":              "members",
          "ownership_kind":          "group",
          "owner_membership_id":     null,
          "custodian_membership_id": null,
          "created_by":              null,
          "created_at":              null,
          "updated_at":              null
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupResource.self, from: json)
        #expect(r.id == rid)
        #expect(r.resourceType == .fund)
        #expect(r.visibility == .members)
        #expect(r.ownershipKind == .group)
        #expect(r.description == "Pagar gasolina")
    }

    @Test("decodes a row returned by create_group_resource (id key)")
    func decodesSetShape() throws {
        let rid = UUID(); let gid = UUID()
        let json = """
        {
          "id":                  "\(rid.uuidString)",
          "group_id":            "\(gid.uuidString)",
          "resource_type":       "space",
          "name":                "Casa",
          "description":         null,
          "status":              "active",
          "visibility":          "private",
          "ownership_kind":      "individual",
          "owner_membership_id": null
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupResource.self, from: json)
        #expect(r.id == rid)
        #expect(r.ownershipKind == .member)
        #expect(r.visibility == .private)
    }

    @Test("unknown enums fall back to safe defaults")
    func enumFallbacks() throws {
        let json = """
        {
          "resource_id":    "\(UUID().uuidString)",
          "group_id":       "\(UUID().uuidString)",
          "resource_type":  "future_kind",
          "name":           "?",
          "status":         "active",
          "visibility":     "future",
          "ownership_kind": "co-op"
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupResource.self, from: json)
        #expect(r.resourceType == .other)
        #expect(r.visibility == .members)
        #expect(r.ownershipKind == .group)
    }

    @Test("ownershipKind.member encodes as 'individual'")
    func ownershipWireToken() {
        #expect(ResourceOwnershipKind.member.rawValue == "individual")
        #expect(ResourceOwnershipKind.group.rawValue == "group")
        #expect(ResourceOwnershipKind.external.rawValue == "external")
    }
}
