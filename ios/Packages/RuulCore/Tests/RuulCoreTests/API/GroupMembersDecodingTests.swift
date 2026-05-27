import Foundation
import Testing
@testable import RuulCore

@Suite("group_members decoding")
struct GroupMembersDecodingTests {

    private func decode(_ json: String) throws -> GroupMemberRow {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GroupMemberRow.self, from: data)
    }

    @Test("snake_case wire row decodes into DTO with all fields")
    func basicRow() throws {
        let membershipId = UUID()
        let userId = UUID()
        let json = """
        {
          "membership_id": "\(membershipId.uuidString)",
          "user_id": "\(userId.uuidString)",
          "display_name": "Jose Mizrahi",
          "username": "jose_m",
          "avatar_url": "https://example.com/a.png",
          "status": "active",
          "membership_type": "member",
          "role_names": ["Tesorero", "Coordinador"],
          "joined_at": null,
          "is_current_user": true
        }
        """
        let row = try decode(json)
        #expect(row.membershipId == membershipId)
        #expect(row.userId == userId)
        #expect(row.displayName == "Jose Mizrahi")
        #expect(row.username == "jose_m")
        #expect(row.avatarUrl == "https://example.com/a.png")
        #expect(row.status == "active")
        #expect(row.membershipType == "member")
        #expect(row.roleNames == ["Tesorero", "Coordinador"])
        #expect(row.isCurrentUser == true)
    }

    @Test("toDomain maps fields, status, and membership_type")
    func mappingToDomain() throws {
        let mid = UUID()
        let json = """
        {
          "membership_id": "\(mid.uuidString)",
          "user_id": null,
          "display_name": "Pending Invitee",
          "username": null,
          "avatar_url": null,
          "status": "invited",
          "membership_type": "provisional",
          "role_names": [],
          "joined_at": null,
          "is_current_user": false
        }
        """
        let row = try decode(json)
        let domain = row.toDomain()
        #expect(domain.id == mid)
        #expect(domain.userId == nil)
        #expect(domain.displayName == "Pending Invitee")
        #expect(domain.status == .invited)
        #expect(domain.membershipType == .provisional)
        #expect(domain.roleNames == [])
        #expect(domain.isCurrentUser == false)
        #expect(domain.avatarURL == nil)
    }

    @Test("unknown status falls back to .active, unknown type to .member")
    func unknownEnumsFallback() throws {
        let json = """
        {
          "membership_id": "\(UUID().uuidString)",
          "user_id": null,
          "display_name": "Mystery",
          "username": null,
          "avatar_url": "",
          "status": "future_status",
          "membership_type": "future_type",
          "role_names": [],
          "joined_at": null,
          "is_current_user": false
        }
        """
        let row = try decode(json)
        let domain = row.toDomain()
        #expect(domain.status == .active)
        #expect(domain.membershipType == .member)
        #expect(domain.avatarURL == nil)
    }
}
