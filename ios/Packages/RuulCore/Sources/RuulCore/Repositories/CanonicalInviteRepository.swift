import Foundation

/// Foundation-scope repository for the invite handshake — issuing a new
/// invite as an authorised member and redeeming a code as the invitee.
/// Coexists with the legacy `InviteRepository` actor; the `Canonical*`
/// prefix is dropped once the old surface is retired.
public struct CanonicalInviteRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// V3-INV: `invite_member` → returns the created invite + its
    /// shareable code + placeholder membership id. Exactly one of
    /// `email` or `phone` must be non-nil.
    public func inviteMember(
        groupId: UUID,
        email: String? = nil,
        phone: String? = nil,
        membershipType: String = "member",
        message: String? = nil
    ) async throws -> InviteCreated {
        try await rpc.inviteMember(
            groupId: groupId,
            email: email,
            phone: phone,
            membershipType: membershipType,
            message: message
        )
    }

    /// V3-INV: `revoke_invite` cancels a pending invitation. Authorized
    /// to the original inviter or anyone with `members.invite`. Backend
    /// blocks if the placeholder membership has any open obligations
    /// (peer-to-peer or pool).
    public func revokeInvite(inviteId: UUID, reason: String? = nil) async throws {
        try await rpc.revokeInvite(inviteId: inviteId, reason: reason)
    }

    /// `accept_invite(p_code)` → returns the joined group id + the new
    /// `group_memberships` row id. The RPC also assigns the group's
    /// `is_default` role so the new member lands with baseline
    /// permissions (canonical_followup_12 fix).
    public func acceptInvite(code: String) async throws -> AcceptInviteResult {
        try await rpc.acceptInvite(code: code)
    }
}
