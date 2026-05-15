import Testing
import Foundation
import RuulUI
import RuulCore
@testable import Tandas

@Suite("Models")
struct ModelsTests {
    @Test("Group decodes from Supabase row")
    func groupDecode() throws {
        let json = """
        {
          "id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "name":"Cena martes",
          "description":null,
          "base_template":"recurring_dinner",
          "invite_code":"abc12345",
          "created_by":"4F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "created_at":"2026-04-30T10:00:00Z"
        }
        """.data(using: .utf8)!
        // Group has explicit CodingKeys with snake_case raw values, so use a
        // plain decoder (not JSONDecoder.tandas) to avoid double-conversion.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let g = try decoder.decode(Group.self, from: json)
        #expect(g.name == "Cena martes")
        #expect(g.effectiveBaseTemplate == "recurring_dinner")
        #expect(g.inviteCode == "abc12345")
    }

    @Test("Profile.displayName empty means onboarding pending")
    func profileEmptyName() throws {
        let json = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","display_name":"","timezone":"America/Mexico_City","locale":"es-MX"}"#.data(using: .utf8)!
        let p = try JSONDecoder.tandas.decode(Profile.self, from: json)
        #expect(p.displayName.isEmpty)
        #expect(p.needsOnboarding)
    }
}
