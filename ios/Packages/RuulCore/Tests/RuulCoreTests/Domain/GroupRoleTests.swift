import Foundation
import Testing
@testable import RuulCore

@Suite("GroupRole + PermissionCatalogEntry domain")
struct GroupRoleTests {

    @Test("GroupRole decodes the canonical row + flattens permission_keys + member_count")
    func decodesRole() throws {
        let rid = UUID(); let gid = UUID()
        let json = """
        {
          "role_id":         "\(rid.uuidString)",
          "group_id":        "\(gid.uuidString)",
          "key":             "treasurer",
          "name":            "Tesorero",
          "description":     "Maneja el dinero.",
          "is_system":       false,
          "is_default":      false,
          "permission_keys": ["money.record_expense","money.record_settlement"],
          "member_count":    2,
          "created_at":      null
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupRole.self, from: json)
        #expect(r.id == rid)
        #expect(r.key == "treasurer")
        #expect(r.permissionKeys.count == 2)
        #expect(r.memberCount == 2)
        #expect(r.isEditable)
        #expect(r.memberCountLabel == "2 miembros")
    }

    @Test("System role is not editable; member_count zero hides chip")
    func systemRoleNotEditable() throws {
        let json = """
        {
          "role_id":         "\(UUID().uuidString)",
          "group_id":        "\(UUID().uuidString)",
          "key":             "founder",
          "name":            "Fundador",
          "is_system":       true,
          "is_default":      false,
          "permission_keys": [],
          "member_count":    0
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupRole.self, from: json)
        #expect(r.isEditable == false)
        #expect(r.memberCountLabel == nil)
    }

    @Test("PermissionCatalogEntry decodes; unknown category falls back to .other")
    func catalogEntryDecodes() throws {
        let known = """
        { "key": "money.record_expense", "description": "Registrar gastos", "category": "money" }
        """.data(using: .utf8)!
        let e1 = try JSONDecoder().decode(PermissionCatalogEntry.self, from: known)
        #expect(e1.category == .money)

        let unknown = """
        { "key": "future.perm", "description": "Algo futuro", "category": "future_cat" }
        """.data(using: .utf8)!
        let e2 = try JSONDecoder().decode(PermissionCatalogEntry.self, from: unknown)
        #expect(e2.category == .other)
    }
}
