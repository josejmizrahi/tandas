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

    /// `invite_member(p_group_id, p_email, p_phone, p_membership_type, p_message)`
    /// → returns the new invite id. Exactly one of `email` or `phone`
    /// must be non-nil; the backend raises `invite requires email or phone`
    /// otherwise, which maps to `.inviteRequiresEmailOrPhone`.
    public func inviteMember(
        groupId: UUID,
        email: String? = nil,
        phone: String? = nil,
        membershipType: String = "member",
        message: String? = nil
    ) async throws -> UUID {
        try await rpc.inviteMember(
            groupId: groupId,
            email: email,
            phone: phone,
            membershipType: membershipType,
            message: message
        )
    }

    /// `accept_invite(p_code)` → returns the joined group id + the new
    /// `group_memberships` row id. The RPC also assigns the group's
    /// `is_default` role so the new member lands with baseline
    /// permissions (canonical_followup_12 fix).
    public func acceptInvite(code: String) async throws -> AcceptInviteResult {
        try await rpc.acceptInvite(code: code)
    }
}
