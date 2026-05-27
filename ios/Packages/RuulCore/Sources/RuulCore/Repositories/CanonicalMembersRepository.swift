import Foundation

/// Foundation-scope repository for the Members surface. Wraps the
/// canonical `group_members(p_group_id)` read helper and delegates the
/// invite mutation to `CanonicalInviteRepository` so the Members store
/// has a single dependency to inject.
///
/// iOS never queries `group_memberships`/`profiles`/`group_member_roles`
/// directly — the RPC pre-joins them and the repo returns ready-to-render
/// `MemberListItem` rows.
public struct CanonicalMembersRepository: Sendable {
    private let rpc: any RuulRPCClient
    private let invites: CanonicalInviteRepository

    public init(rpc: any RuulRPCClient, invites: CanonicalInviteRepository) {
        self.rpc = rpc
        self.invites = invites
    }

    /// Lists the group's members visible to Foundation
    /// (active/invited/requested/suspended). Excludes left/banned.
    public func listMembers(groupId: UUID) async throws -> [MemberListItem] {
        try await rpc.groupMembers(groupId: groupId)
    }

    /// Forwards the invite to `CanonicalInviteRepository`. Returns the
    /// new `group_invites.id` so callers can correlate UI flows.
    public func inviteMember(
        groupId: UUID,
        email: String?,
        phone: String?,
        membershipType: MembershipType,
        message: String?
    ) async throws -> UUID {
        try await invites.inviteMember(
            groupId: groupId,
            email: email,
            phone: phone,
            membershipType: membershipType.rawValue,
            message: message
        )
    }
}
