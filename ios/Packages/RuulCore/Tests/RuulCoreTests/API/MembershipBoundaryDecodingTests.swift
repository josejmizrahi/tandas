import Foundation
import Testing
@testable import RuulCore

@Suite("group_membership_boundary decoding")
struct MembershipBoundaryDecodingTests {

    private func decode(_ json: String) throws -> MembershipBoundaryItem {
        try JSONDecoder().decode(MembershipBoundaryItem.self, from: json.data(using: .utf8)!)
    }

    @Test("membership row decodes")
    func membershipRow() throws {
        let bid = UUID(); let mid = UUID(); let uid = UUID()
        let json = """
        {
          "boundary_id":     "\(bid.uuidString)",
          "boundary_kind":   "membership",
          "membership_id":   "\(mid.uuidString)",
          "invite_id":       null,
          "user_id":         "\(uid.uuidString)",
          "display_name":    "Ana López",
          "username":        "ana_l",
          "avatar_url":      "https://example.com/a.png",
          "status":          "active",
          "membership_type": "member",
          "role_names":      ["Tesorero"],
          "joined_at":       null,
          "invited_at":      null,
          "is_current_user": false
        }
        """
        let item = try decode(json)
        #expect(item.id == bid)
        #expect(item.kind == .membership)
        #expect(item.membershipId == mid)
        #expect(item.inviteId == nil)
        #expect(item.userId == uid)
        #expect(item.displayName == "Ana López")
        #expect(item.username == "ana_l")
        #expect(item.status == .active)
        #expect(item.membershipType == .member)
        #expect(item.roleNames == ["Tesorero"])
        #expect(item.canNavigateToMember == true)
        #expect(item.isPendingInvite == false)
        #expect(item.subtitle == "Tesorero")
    }

    @Test("pending invite row decodes with email fallback and 'Invitación pendiente' subtitle")
    func inviteRow() throws {
        let bid = UUID(); let iid = UUID()
        let json = """
        {
          "boundary_id":     "\(bid.uuidString)",
          "boundary_kind":   "invite",
          "membership_id":   null,
          "invite_id":       "\(iid.uuidString)",
          "user_id":         null,
          "display_name":    "carlos@email.com",
          "username":        null,
          "avatar_url":      null,
          "status":          "invited",
          "membership_type": "provisional",
          "role_names":      [],
          "joined_at":       null,
          "invited_at":      null,
          "is_current_user": false
        }
        """
        let item = try decode(json)
        #expect(item.kind == .invite)
        #expect(item.membershipId == nil)
        #expect(item.inviteId == iid)
        #expect(item.status == .invited)
        #expect(item.membershipType == .provisional)
        #expect(item.isPendingInvite == true)
        #expect(item.canNavigateToMember == false)
        #expect(item.subtitle == "Invitación pendiente")
    }

    @Test("unknown enum values fall back to safe defaults; empty avatar → nil")
    func defensiveFallbacks() throws {
        let json = """
        {
          "boundary_id":     "\(UUID().uuidString)",
          "boundary_kind":   "future_kind",
          "membership_id":   null,
          "invite_id":       null,
          "user_id":         null,
          "display_name":    "Mystery",
          "username":        null,
          "avatar_url":      "",
          "status":          "future_status",
          "membership_type": "future_type",
          "role_names":      [],
          "joined_at":       null,
          "invited_at":      null,
          "is_current_user": false
        }
        """
        let item = try decode(json)
        #expect(item.kind == .membership)
        #expect(item.status == .active)
        #expect(item.membershipType == .member)
        #expect(item.avatarURL == nil)
    }
}
