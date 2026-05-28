import Foundation
import Testing
@testable import RuulCore

@Suite("GroupBoundaryPolicy domain")
struct GroupBoundaryPolicyTests {

    @Test("decodes the canonical jsonb returned by group_boundary_policy")
    func decodesPolicy() throws {
        let gid = UUID()
        let json = """
        {
          "group_id":           "\(gid.uuidString)",
          "entry_mode":         "open",
          "who_can_invite":     "admins_only",
          "requires_approval":  true,
          "exit_mode":          "requires_notice",
          "notes":              "Solo admins invitan.",
          "is_default":         false
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(GroupBoundaryPolicy.self, from: json)
        #expect(p.groupId == gid)
        #expect(p.entryMode == .open)
        #expect(p.whoCanInvite == .adminsOnly)
        #expect(p.requiresApproval)
        #expect(p.exitMode == .requiresNotice)
        #expect(p.notes == "Solo admins invitan.")
        #expect(p.isDefault == false)
    }

    @Test("Unknown enum values fall back to safe defaults")
    func decodesUnknownEnums() throws {
        let gid = UUID()
        let json = """
        {
          "group_id":          "\(gid.uuidString)",
          "entry_mode":        "future_mode",
          "who_can_invite":    "future_scope",
          "requires_approval": false,
          "exit_mode":         "future_exit",
          "is_default":        true
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(GroupBoundaryPolicy.self, from: json)
        #expect(p.entryMode == .inviteOnly)
        #expect(p.whoCanInvite == .anyMember)
        #expect(p.exitMode == .free)
        #expect(p.isDefault)
    }

    @Test("trimmedNotes returns nil for whitespace-only notes")
    func trimmedNotesHelper() {
        let withNotes = GroupBoundaryPolicy(groupId: UUID(), notes: "  hola  ")
        #expect(withNotes.trimmedNotes == "hola")
        let blank = GroupBoundaryPolicy(groupId: UUID(), notes: "   ")
        #expect(blank.trimmedNotes == nil)
        let none = GroupBoundaryPolicy(groupId: UUID(), notes: nil)
        #expect(none.trimmedNotes == nil)
    }
}
