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
                until: (newState == .suspended || newState == .paused) ? until : nil
            )
        )
    }

    /// D.22 — governance-aware membership state change. For terminal
    /// states (`.banned` / `.removed`) routes through
    /// `request_or_execute_action` so member-level callers open a
    /// decision and founder-level callers proceed direct via the
    /// override. For other states this falls through to the legacy
    /// direct call and returns `.directAllowed`.
    public func setMembershipStateViaGovernance(
        groupId: UUID,
        membershipId: UUID,
        newState: MembershipStatus,
        reason: String? = nil,
        until: Date? = nil
    ) async throws -> ActionOutcome {
        let trimmedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank

        let actionKey: String? = switch newState {
        case .banned:  "membership.ban"
        case .removed: "membership.remove"
        default:       nil  // non-terminal states stay direct
        }

        guard let actionKey else {
            try await setMembershipState(
                membershipId: membershipId, newState: newState, reason: trimmedReason, until: until
            )
            return .directAllowed(plan: .init(
                actionKey: "membership.\(newState.rawValue)",
                executableRPC: "set_membership_state",
                targetKind: "membership",
                targetId: membershipId,
                reason: "direct_by_default",
                isFounder: false, isAdmin: false, riskLevel: "medium"
            ))
        }

        var payload: [String: RPCJSONValue] = [
            "target_state": .string(newState.rawValue)
        ]
        if let trimmedReason { payload["reason"] = .string(trimmedReason) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId: groupId,
                actionKey: actionKey,
                targetKind: "membership",
                targetId: membershipId,
                payload: payload
            )
        )

        if case .directAllowed = outcome {
            try await setMembershipState(
                membershipId: membershipId, newState: newState, reason: trimmedReason, until: until
            )
        }
        return outcome
    }

    // MARK: - V3-D.20

    /// `approve_membership_request(p_membership_id)` — admin-side
    /// acceptance of a join request. Gated server-side by
    /// `members.invite`. Idempotent.
    public func approveRequest(membershipId: UUID) async throws -> ApproveMembershipRequestResult {
        try await rpc.approveMembershipRequest(membershipId: membershipId)
    }

    /// `membership_provenance(p_membership_id)` — "¿por qué este estado?"
    public func provenance(membershipId: UUID) async throws -> MembershipProvenance {
        try await rpc.membershipProvenance(membershipId: membershipId)
    }

    /// `list_membership_transitions()` — canonical catalog (read-only).
    public func transitions() async throws -> [MembershipStateTransition] {
        try await rpc.listMembershipTransitions()
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
