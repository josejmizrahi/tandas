import Testing
import Foundation
@testable import Tandas

@Suite("Models")
struct ModelsTests {
    @Test("GroupType decodes snake_case from Supabase")
    func groupTypeSnakeCase() throws {
        let json = #"{"group_type":"recurring_dinner"}"#.data(using: .utf8)!
        struct Wrap: Decodable { let groupType: GroupType }
        let decoder = JSONDecoder.tandas
        let wrap = try decoder.decode(Wrap.self, from: json)
        #expect(wrap.groupType == .recurringDinner)
    }

    @Test("Group decodes from Supabase row")
    func groupDecode() throws {
        let json = """
        {
          "id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "name":"Cena martes",
          "description":null,
          "group_type":"recurring_dinner",
          "invite_code":"abc12345",
          "created_at":"2026-04-30T10:00:00Z"
        }
        """.data(using: .utf8)!
        let g = try JSONDecoder.tandas.decode(Group.self, from: json)
        #expect(g.name == "Cena martes")
        #expect(g.groupType == .recurringDinner)
        #expect(g.inviteCode == "abc12345")
    }

    @Test("Profile.displayName empty means onboarding pending")
    func profileEmptyName() throws {
        let json = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","display_name":""}"#.data(using: .utf8)!
        let p = try JSONDecoder.tandas.decode(Profile.self, from: json)
        #expect(p.displayName.isEmpty)
        #expect(p.needsOnboarding)
    }
}
