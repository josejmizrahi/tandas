import Foundation
import Testing
@testable import RuulCore

@Suite("Profile domain")
struct ProfileTests {

    // MARK: - hasUsableDisplayName

    @Test("nil displayName → false")
    func nilNotUsable() {
        let p = Profile(id: UUID(), displayName: nil)
        #expect(p.hasUsableDisplayName == false)
    }

    @Test("empty displayName → false")
    func emptyNotUsable() {
        let p = Profile(id: UUID(), displayName: "")
        #expect(p.hasUsableDisplayName == false)
    }

    @Test("whitespace-only displayName → false")
    func whitespaceNotUsable() {
        let p = Profile(id: UUID(), displayName: "   ")
        #expect(p.hasUsableDisplayName == false)
        let n = Profile(id: UUID(), displayName: "\n\t ")
        #expect(n.hasUsableDisplayName == false)
    }

    @Test("real name → true")
    func realNameUsable() {
        let p = Profile(id: UUID(), displayName: "Jose")
        #expect(p.hasUsableDisplayName == true)
    }

    // MARK: - resolvedDisplayName

    @Test("resolvedDisplayName prefers displayName, then username, then fallback")
    func resolvedDisplayNameFallback() {
        let withName = Profile(id: UUID(), username: "u", displayName: "Jose")
        #expect(withName.resolvedDisplayName == "Jose")

        let onlyUsername = Profile(id: UUID(), username: "jose_m", displayName: nil)
        #expect(onlyUsername.resolvedDisplayName == "jose_m")

        let empty = Profile(id: UUID(), username: nil, displayName: nil)
        #expect(empty.resolvedDisplayName == "Miembro")

        let whitespaceDisplay = Profile(id: UUID(), username: "u", displayName: "   ")
        #expect(whitespaceDisplay.resolvedDisplayName == "u")
    }

    // MARK: - Codable

    @Test("decodes snake_case JSON into camelCase domain")
    func snakeCaseDecode() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "username": "jose_m",
          "display_name": "Jose Mizrahi",
          "avatar_url": "https://example.com/a.png",
          "bio": "Founder",
          "created_at": null,
          "updated_at": null
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Profile.self, from: json)
        #expect(p.id == id)
        #expect(p.username == "jose_m")
        #expect(p.displayName == "Jose Mizrahi")
        #expect(p.avatarURL?.absoluteString == "https://example.com/a.png")
        #expect(p.bio == "Founder")
    }

    @Test("decodes blank avatar_url as nil URL")
    func blankAvatarDecodesNil() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","avatar_url":""}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Profile.self, from: json)
        #expect(p.avatarURL == nil)
    }
}
