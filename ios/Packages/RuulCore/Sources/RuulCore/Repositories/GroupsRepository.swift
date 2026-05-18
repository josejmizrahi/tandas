import Foundation
import Supabase

public enum GroupsError: Error, Equatable {
    case inviteCodeNotFound
    case rpcFailed(String)
    case notFound
}

public protocol GroupsRepository: Actor {
    // Read
    func listMine() async throws -> [Group]
    func get(_ id: UUID) async throws -> GroupDetail
    func members(of groupId: UUID) async throws -> [Member]
    func membersWithProfiles(of groupId: UUID) async throws -> [MemberWithProfile]

    // Create / Join / Leave
    func create(_ params: CreateGroupParams) async throws -> Group
    func createInitial(_ draft: GroupDraft) async throws -> Group
    func joinByCode(_ code: String) async throws -> Group
    func leave(_ id: UUID) async throws

    // Mutations
    func updateConfig(groupId: UUID, patch: GroupConfigPatch) async throws -> Group
    func updateGovernance(groupId: UUID, rules: GovernanceRules) async throws -> Group
    func fetchPreview(byInviteCode code: String) async throws -> InvitePreview

    // Member management
    func setTurnOrder(groupId: UUID, userIds: [UUID]) async throws
    /// Admin-driven removal via the `remove_member` RPC (mig 00115).
    /// Soft-deletes the member's row and emits a `memberLeft` system
    /// event. Caller must be a group admin.
    func removeMember(groupId: UUID, userId: UUID, reason: String?) async throws
    /// Self-leave via the `leave_group` RPC (mig 00115). Soft-deletes
    /// the calling user's membership and emits a `memberLeft` event
    /// with reason=self_leave.
    func leaveGroup(groupId: UUID) async throws

    // Module lifecycle
    func setModule(groupId: UUID, slug: String, enabled: Bool) async throws -> Group

    /// Rotates `groups.invite_code` via the `regenerate_invite_code` RPC
    /// (mig 00176). Server gates by Permission.modifyGovernance — UI
    /// should hide the affordance for unauthorised actors, but the RPC
    /// is fail-closed regardless. Returns the new code (lowercase, 8
    /// chars) so the caller can show it without re-fetching the group.
    func regenerateInviteCode(groupId: UUID) async throws -> String

    /// Uploads a new group avatar and updates `groups.avatar_url`.
    /// Storage path: `group_avatars/{groupId}/avatar-{ts}.{ext}`.
    /// Caller must be a group admin — server enforces via RLS on
    /// storage.objects (mig 00176) and on `groups` (groups_update_admin).
    func updateAvatar(groupId: UUID, data: Data, contentType: String) async throws -> URL

    /// Archives the group via `archive_group` RPC (mig 00177). Admin-only.
    /// Hidden from default lists; restorable by the founder via `unarchive`.
    func archive(groupId: UUID) async throws

    /// Restores an archived group via `unarchive_group` RPC. Only the
    /// founder who archived can restore.
    func unarchive(groupId: UUID) async throws

    // MARK: - RolesV2 (Phase 5) — mig 00229 / 00230

    /// Assigns `role` to the target member via `assign_role` RPC
    /// (mig 00229). Server gates by `has_permission(assignRoles)` or
    /// legacy `is_group_admin`. Idempotent — re-assigning an existing
    /// role is a no-op. Returns the updated `Member` row.
    func assignRole(groupId: UUID, userId: UUID, role: String) async throws -> Member

    /// Removes `role` from the target member via `unassign_role` RPC
    /// (mig 00229). Server protects the `member` baseline and the last
    /// `founder` of the group. Idempotent.
    func unassignRole(groupId: UUID, userId: UUID, role: String) async throws -> Member

    /// Creates or updates an entry in `groups.roles` via
    /// `upsert_group_role` RPC (mig 00230). System roles
    /// (`founder`/`member`) keep their `system: true` flag; founder
    /// retains the `assignRoles` permission as a lockout safeguard.
    func upsertGroupRole(
        groupId: UUID,
        roleId: String,
        label: String?,
        permissions: [Permission],
        maxHolders: Int?
    ) async throws -> Group

    /// Removes a custom role from `groups.roles` and cascades to strip
    /// the role from every membership in the group via
    /// `delete_group_role` RPC (mig 00230). System roles cannot be
    /// deleted.
    func deleteGroupRole(groupId: UUID, roleId: String) async throws -> Group
}

/// Partial update payload for the new bare-group config.
/// Post BigBang most settings live elsewhere (capability blocks, modules,
/// resource_series, governance jsonb), so this struct shrinks to the
/// fields that still belong on the bare Group.
public struct GroupConfigPatch: Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var initialEventVocabulary: String?
    public var coverImageName: String?
    public var currency: String?
    public var timezone: String?

    public init(
        name: String? = nil,
        description: String? = nil,
        initialEventVocabulary: String? = nil,
        coverImageName: String? = nil,
        currency: String? = nil,
        timezone: String? = nil
    ) {
        self.name = name
        self.description = description
        self.initialEventVocabulary = initialEventVocabulary
        self.coverImageName = coverImageName
        self.currency = currency
        self.timezone = timezone
    }
}

