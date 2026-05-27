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
}
