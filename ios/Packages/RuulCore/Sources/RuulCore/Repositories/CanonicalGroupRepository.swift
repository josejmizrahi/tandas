import Foundation

/// Foundation-scope repository for group identity + membership reads and
/// the self-exit mutation. Thin wrapper over `RuulRPCClient` so feature
/// view models stay decoupled from Supabase — repos never import Supabase
/// directly.
///
/// Slice 2 (Foundation iOS rebuild) — coexists with the legacy
/// `GroupsRepository` (plural) until the old surface is retired.
public struct CanonicalGroupRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// `create_group(p_name, p_slug, p_category, p_purpose_declared)` →
    /// returns the new group id. Caller's auth user is auto-promoted to
    /// the founder mandate role inside the RPC; no follow-up call needed.
    public func createGroup(
        name: String,
        slug: String? = nil,
        category: String? = nil,
        purposeDeclared: String? = nil
    ) async throws -> UUID {
        try await rpc.createGroup(
            name: name,
            slug: slug,
            category: category,
            purposeDeclared: purposeDeclared
        )
    }

    /// Lists every group the caller is an active member of. RLS on
    /// `group_memberships` + embedded `groups` join enforces visibility.
    public func listMyGroups() async throws -> [GroupListItem] {
        try await rpc.listMyGroups()
    }

    /// `leave_group(p_group_id, p_reason)` — self-exit only. The
    /// canonical RPC enforces that the caller has an active membership;
    /// admins removing others use a different (deferred) RPC.
    public func leaveGroup(groupId: UUID, reason: String? = nil) async throws {
        try await rpc.leaveGroup(groupId: groupId, reason: reason)
    }

    /// `group_summary(p_group_id) returns jsonb` — counts + recent events
    /// for the home/header chrome. Decoded into `CanonicalGroupSummary`.
    public func groupSummary(groupId: UUID) async throws -> CanonicalGroupSummary {
        try await rpc.groupSummary(groupId: groupId)
    }

    /// `list_member_permissions(p_group_id, p_user_id)` — string keys the
    /// caller (or a target user) holds in this group. iOS uses this purely
    /// for UI gating; never as authority of record.
    public func listMemberPermissions(groupId: UUID, userId: UUID? = nil) async throws -> [String] {
        try await rpc.listMemberPermissions(groupId: groupId, userId: userId)
    }

    /// D.24 — `request_membership(p_group_id, p_message)` returns the new
    /// `requested` membership_id. Caller becomes `status='requested'` in
    /// the target group; an admin with `members.invite` approves via
    /// `approve_membership_request`. Useful for groups whose policy
    /// permits join requests instead of invite-only entry.
    public func requestMembership(groupId: UUID, message: String? = nil) async throws -> UUID {
        try await rpc.requestMembership(RequestMembershipParams(groupId: groupId, message: message))
    }

    /// V3 D.24 P12A — single-round-trip Home payload. Group + membership +
    /// permissions + 3 counts + last 10 activity. iOS P12B-1 lo adopta en
    /// `GroupHomeFeedView` via `GroupHomeSummaryStore`. Mantiene fallback
    /// legacy en la vista si falla esta RPC.
    public func homeSummary(groupId: UUID) async throws -> GroupHomeSummary {
        try await rpc.groupHomeSummary(groupId: groupId)
    }
}
