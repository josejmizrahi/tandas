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

    /// Primitiva 2: unified boundary view (memberships ∪ pending
    /// invites). One row per person who currently has a relationship
    /// with the group, with `boundary_kind` distinguishing real
    /// memberships from outstanding invites.
    public func membershipBoundary(groupId: UUID) async throws -> [MembershipBoundaryItem] {
        try await rpc.groupMembershipBoundary(groupId: groupId)
    }

    /// Forwards the invite to `CanonicalInviteRepository`. V3-INV: now
    /// returns the full `InviteCreated` (invite id + shareable code +
    /// placeholder membership id) so the UI can drop the user into a
    /// share/copy flow right after sending.
    public func inviteMember(
        groupId: UUID,
        email: String?,
        phone: String?,
        membershipType: MembershipType,
        message: String?
    ) async throws -> InviteCreated {
        try await invites.inviteMember(
            groupId: groupId,
            email: email,
            phone: phone,
            membershipType: membershipType.rawValue,
            message: message
        )
    }

    /// V3-INV: cancel a pending invitation.
    public func revokeInvite(inviteId: UUID, reason: String? = nil) async throws {
        try await invites.revokeInvite(inviteId: inviteId, reason: reason)
    }

    /// Wraps `set_membership_state`. Permission gating is server-side:
    /// `members.suspend` for suspended, `members.remove` for banned,
    /// `members.update` for the rest. `until` is only persisted when
    /// the state is `.suspended`.
    public func setMembershipState(
        membershipId: UUID,
        newState: MembershipStatus,
        reason: String? = nil,
        until: Date? = nil
    ) async throws {
        let trimmed = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        try await rpc.setMembershipState(
            SetMembershipStateParams(
                membershipId: membershipId,
                newState: newState.rawValue,
                reason: trimmed,
                until: newState == .suspended ? until : nil
            )
        )
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
