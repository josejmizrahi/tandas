import Foundation
import Supabase

public enum GroupsError: Error, Equatable {
    case inviteCodeNotFound
    case rpcFailed(String)
    case notFound
}

public protocol GroupsRepository: Actor {
    // Phase 1
    func listMine() async throws -> [Group]
    func get(_ id: UUID) async throws -> GroupDetail
    func create(_ params: CreateGroupParams) async throws -> Group
    func joinByCode(_ code: String) async throws -> Group
    func leave(_ id: UUID) async throws
    func members(of groupId: UUID) async throws -> [Member]
    func membersWithProfiles(of groupId: UUID) async throws -> [MemberWithProfile]

    // Onboarding V1
    func createInitial(_ draft: GroupDraft) async throws -> Group
    func updateConfig(groupId: UUID, patch: GroupConfigPatch) async throws -> Group
    func updateGovernance(groupId: UUID, rules: GovernanceRules) async throws -> Group
    func fetchPreview(byInviteCode code: String) async throws -> InvitePreview

    // F0 #4 — Member management (EditMembersSheet)
    /// Reorders the rotating-host queue. Server RPC `set_turn_order` (00004)
    /// is admin-only and only touches active members; pass user_ids in the
    /// desired turn order. Caller is expected to have already gated by
    /// GovernanceService for the relevant action (host rotation reorder).
    func setTurnOrder(groupId: UUID, userIds: [UUID]) async throws
    /// Hard-deletes a `group_members` row. RLS policy `members_delete` (00002)
    /// allows this if the caller is the same user (self-leave) OR a group
    /// admin. UI callers should gate destructive actions through
    /// `GovernanceService.canPerform(.removeMembers, ...)` first.
    func removeMember(memberId: UUID) async throws

    // Primitives § 3 slice 3 — module write-path
    /// Toggles module slug membership in `groups.active_modules`. Admin-gated
    /// at the RPC layer (`set_group_module`, mig 00055). The trigger from
    /// mig 00049 keeps `fines_enabled` derived when `slug == "basic_fines"`,
    /// so callers do not need to also patch the legacy column. Idempotent —
    /// enabling an already-on module (or disabling an already-off one) is a
    /// no-op on the underlying jsonb.
    func setModule(groupId: UUID, slug: String, enabled: Bool) async throws -> Group
}

/// Partial update payload for `update_group_config` RPC. All optional —
/// only set fields are sent.
public struct GroupConfigPatch: Sendable, Equatable {
    public var eventLabel: String?
    public var frequencyType: FrequencyType?
    public var frequencyConfig: FrequencyConfig?
    public var finesEnabled: Bool?
    public var rotationMode: RotationMode?
    public var coverImageName: String?

    public init(eventLabel: String? = nil, frequencyType: FrequencyType? = nil, frequencyConfig: FrequencyConfig? = nil, finesEnabled: Bool? = nil, rotationMode: RotationMode? = nil, coverImageName: String? = nil) {
        self.eventLabel = eventLabel
        self.frequencyType = frequencyType
        self.frequencyConfig = frequencyConfig
        self.finesEnabled = finesEnabled
        self.rotationMode = rotationMode
        self.coverImageName = coverImageName
    }
}

// MARK: - Mock

public actor MockGroupsRepository: GroupsRepository {
    private var _groups: [Group]
    private var _members: [UUID: [Member]] = [:]
    /// Optional preseeded `MemberWithProfile` rows so tests can control the
    /// effective `displayName` returned by `membersWithProfiles(of:)`. When
    /// non-empty, takes precedence over `_members` (which only stores raw
    /// `Member` rows and synthesizes a stub Profile).
    private var _membersWithProfiles: [MemberWithProfile] = []
    public var nextCreateError: GroupsError?
    public var nextPreviewError: GroupsError?

    /// Module registry used by `setModule` to mirror the SQL cascade
    /// closures locally. Defaults to `v1Fallback`; tests can pass a
    /// custom registry to exercise Phase 2+ deps without seeding the DB.
    private let modules: ModuleRegistry

    public init(seed: [Group] = [], modules: ModuleRegistry = .v1Fallback) {
        self._groups = seed
        self.modules = modules
    }

    /// Test convenience: seed a flat list of `MemberWithProfile` rows.
    /// `membersWithProfiles(of:)` filters this list by `member.groupId`.
    public init(
        membersWithProfilesSeed: [MemberWithProfile],
        modules: ModuleRegistry = .v1Fallback
    ) {
        self._groups = []
        self._membersWithProfiles = membersWithProfilesSeed
        self.modules = modules
    }

    public func listMine() async throws -> [Group] { _groups }

    public func get(_ id: UUID) async throws -> GroupDetail {
        guard let g = _groups.first(where: { $0.id == id }) else { throw GroupsError.notFound }
        return GroupDetail(group: g, memberCount: _members[id]?.count ?? 1, myRole: "admin")
    }

    public func create(_ p: CreateGroupParams) async throws -> Group {
        let g = Group(
            id: UUID(),
            name: p.name,
            description: p.description,
            inviteCode: String(UUID().uuidString.prefix(8)).lowercased(),
            coverImageName: p.coverImageName,
            eventVocabulary: p.eventLabel,
            baseTemplate: p.baseTemplate,
            createdBy: UUID(),
            createdAt: .now
        )
        _groups.append(g)
        return g
    }

    public func joinByCode(_ code: String) async throws -> Group {
        guard let g = _groups.first(where: { $0.inviteCode == code }) else {
            throw GroupsError.inviteCodeNotFound
        }
        return g
    }

    public func leave(_ id: UUID) async throws {
        _groups.removeAll { $0.id == id }
    }

    public func members(of groupId: UUID) async throws -> [Member] {
        _members[groupId] ?? []
    }

    public func membersWithProfiles(of groupId: UUID) async throws -> [MemberWithProfile] {
        if !_membersWithProfiles.isEmpty {
            return _membersWithProfiles.filter { $0.member.groupId == groupId }
        }
        return (_members[groupId] ?? []).map { m in
            MemberWithProfile(
                member: m,
                profile: Profile(id: m.userId, displayName: "Miembro", avatarUrl: nil, phone: nil)
            )
        }
    }

    public func createInitial(_ draft: GroupDraft) async throws -> Group {
        if let err = nextCreateError { nextCreateError = nil; throw err }
        let g = Group(
            id: UUID(),
            name: draft.name,
            inviteCode: String(UUID().uuidString.prefix(8)).lowercased(),
            coverImageName: draft.coverImageName,
            eventVocabulary: draft.resolvedVocabulary,
            frequencyType: draft.frequencyType,
            frequencyConfig: draft.frequencyConfig,
            finesEnabled: draft.finesEnabled,
            rotationMode: draft.rotationMode,
            baseTemplate: draft.template,
            createdBy: UUID(),
            createdAt: .now
        )
        _groups.append(g)
        return g
    }

    public func updateConfig(groupId: UUID, patch: GroupConfigPatch) async throws -> Group {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let g = _groups[idx]
        let updated = Group(
            id: g.id,
            name: g.name,
            description: g.description,
            inviteCode: g.inviteCode,
            coverImageName: patch.coverImageName ?? g.coverImageName,
            eventVocabulary: patch.eventLabel ?? g.eventVocabulary,
            frequencyType: patch.frequencyType ?? g.frequencyType,
            frequencyConfig: patch.frequencyConfig ?? g.frequencyConfig,
            finesEnabled: patch.finesEnabled ?? g.finesEnabled,
            rotationMode: patch.rotationMode ?? g.rotationMode,
            baseTemplate: g.baseTemplate,
            activeModules: g.activeModules,
            governance: g.governance,
            settings: g.settings,
            category: g.category,
            initials: g.initials,
            avatarUrl: g.avatarUrl,
            createdBy: g.createdBy,
            createdAt: g.createdAt
        )
        _groups[idx] = updated
        return updated
    }

    public func updateGovernance(groupId: UUID, rules: GovernanceRules) async throws -> Group {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let g = _groups[idx]
        let updated = Group(
            id: g.id, name: g.name, description: g.description,
            inviteCode: g.inviteCode,
            coverImageName: g.coverImageName, eventVocabulary: g.eventVocabulary,
            frequencyType: g.frequencyType, frequencyConfig: g.frequencyConfig,
            finesEnabled: g.finesEnabled, rotationMode: g.rotationMode,
            baseTemplate: g.baseTemplate, activeModules: g.activeModules,
            governance: rules, settings: g.settings,
            category: g.category, initials: g.initials, avatarUrl: g.avatarUrl,
            createdBy: g.createdBy, createdAt: g.createdAt
        )
        _groups[idx] = updated
        return updated
    }

    public func fetchPreview(byInviteCode code: String) async throws -> InvitePreview {
        if let err = nextPreviewError { nextPreviewError = nil; throw err }
        guard let g = _groups.first(where: { $0.inviteCode == code }) else {
            throw GroupsError.inviteCodeNotFound
        }
        return InvitePreview(
            groupId: g.id,
            groupName: g.name,
            coverImageName: g.coverImageName,
            eventLabel: g.eventVocabulary,
            frequencyType: g.frequencyType?.rawValue,
            inviteCode: g.inviteCode,
            groupCreatedAt: g.createdAt,
            memberCount: _members[g.id]?.count ?? 1,
            recentMemberNames: nil
        )
    }

    // MARK: - F0 #4 (member management)

    /// Persisted turn orders captured by the most recent `setTurnOrder` call.
    /// Tests can read this via `lastTurnOrder(for:)` to assert UI wiring.
    private var _turnOrders: [UUID: [UUID]] = [:]

    public func setTurnOrder(groupId: UUID, userIds: [UUID]) async throws {
        _turnOrders[groupId] = userIds
    }

    public func lastTurnOrder(for groupId: UUID) -> [UUID]? { _turnOrders[groupId] }

    public func removeMember(memberId: UUID) async throws {
        // Strip from any seeded `_members` entry and from
        // `_membersWithProfiles` so the next fetch reflects the deletion.
        for (gid, list) in _members {
            _members[gid] = list.filter { $0.id != memberId }
        }
        _membersWithProfiles.removeAll { $0.member.id == memberId }
    }

    // MARK: - Primitives § 3 slice 3 (module write-path)

    /// Mirrors `set_group_module` RPC + the mig 00049 trigger client-side so
    /// tests using `MockGroupsRepository` see the same invariants the DB
    /// enforces: `fines_enabled = ('basic_fines' = ANY(active_modules))`.
    /// Also applies the same transitive dep/dependent cascade as the SQL
    /// version (mig 00057): enabling a module pulls in its deps, disabling
    /// a module also disables anything that requires it.
    public func setModule(groupId: UUID, slug: String, enabled: Bool) async throws -> Group {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let g = _groups[idx]
        var modules = g.effectiveActiveModules
        if enabled {
            if !modules.contains(slug) { modules.append(slug) }
            for dep in self.modules.transitiveDependencies(of: slug)
            where !modules.contains(dep) {
                modules.append(dep)
            }
        } else {
            modules.removeAll { $0 == slug }
            let dependents = Set(self.modules.transitiveDependents(of: slug))
            modules.removeAll { dependents.contains($0) }
        }
        let derivedFinesEnabled: Bool = modules.contains(GroupModule.basicFines.id)
        let updated = Group(
            id: g.id,
            name: g.name,
            description: g.description,
            inviteCode: g.inviteCode,
            coverImageName: g.coverImageName,
            eventVocabulary: g.eventVocabulary,
            frequencyType: g.frequencyType,
            frequencyConfig: g.frequencyConfig,
            finesEnabled: derivedFinesEnabled,
            rotationMode: g.rotationMode,
            baseTemplate: g.baseTemplate,
            activeModules: modules,
            governance: g.governance,
            settings: g.settings,
            category: g.category,
            initials: g.initials,
            avatarUrl: g.avatarUrl,
            createdBy: g.createdBy,
            createdAt: g.createdAt
        )
        _groups[idx] = updated
        return updated
    }
}

// MARK: - Live

public actor LiveGroupsRepository: GroupsRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func listMine() async throws -> [Group] {
        let userId = try await client.auth.session.user.id
        struct Row: Decodable { let groups: Group }
        let rows: [Row] = try await client
            .from("group_members")
            .select("groups(*)")
            .eq("user_id", value: userId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
        return rows.map(\.groups)
    }

    public func get(_ id: UUID) async throws -> GroupDetail {
        let group: Group = try await client
            .from("groups")
            .select("*")
            .eq("id", value: id.uuidString.lowercased())
            .single()
            .execute()
            .value
        struct CountRow: Decodable { let count: Int }
        let countRow: [CountRow] = try await client
            .from("group_members")
            .select("count", head: false, count: .exact)
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
        let userId = try await client.auth.session.user.id
        struct RoleRow: Decodable { let role: String }
        let role: RoleRow? = try? await client
            .from("group_members")
            .select("role")
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return GroupDetail(
            group: group,
            memberCount: countRow.first?.count ?? 1,
            myRole: role?.role ?? "member"
        )
    }

    public func create(_ p: CreateGroupParams) async throws -> Group {
        // Legacy path used by Phase 1. New onboarding uses createInitial(_:).
        struct Params: Encodable {
            let p_name: String
            let p_event_label: String?
            let p_currency: String?
            let p_timezone: String?
            let p_base_template: String?
            let p_cover_image_name: String?
        }
        let params = Params(
            p_name: p.name,
            p_event_label: p.eventLabel,
            p_currency: p.currency,
            p_timezone: "America/Mexico_City",
            p_base_template: p.baseTemplate,
            p_cover_image_name: p.coverImageName
        )
        do {
            let g: Group = try await client
                .rpc("create_group_with_admin", params: params)
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func joinByCode(_ code: String) async throws -> Group {
        struct Params: Encodable { let p_code: String }
        do {
            let g: Group = try await client
                .rpc("join_group_by_code", params: Params(p_code: code))
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.inviteCodeNotFound
        }
    }

    public func leave(_ id: UUID) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("group_members")
            .update(["active": false])
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
    }

    public func members(of groupId: UUID) async throws -> [Member] {
        try await client
            .from("group_members")
            .select("id, group_id, user_id, display_name_override, role, active, joined_at")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
    }

    /// Fetch members + profiles in two queries (members → profiles).
    /// Previously tried a single PostgREST nested select with `profiles(*)`
    /// but that 400'd because `group_members.user_id` FKs to `auth.users.id`,
    /// not `public.profiles.id`, so PostgREST couldn't infer the embed
    /// relationship. Splitting is robust and only adds one round-trip.
    public func membersWithProfiles(of groupId: UUID) async throws -> [MemberWithProfile] {
        let members: [Member] = try await client
            .from("group_members")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value

        if members.isEmpty { return [] }

        let userIds = members.map { $0.userId.uuidString.lowercased() }
        let profiles: [Profile] = (try? await client
            .from("profiles")
            .select("*")
            .in("id", values: userIds)
            .execute()
            .value) ?? []

        let profilesByUserId = Dictionary(
            profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let rows: [(member: Member, profile: Profile?)] = members.map { m in
            (m, profilesByUserId[m.userId])
        }

        return rows.map { MemberWithProfile(member: $0.member, profile: $0.profile) }
    }

    // MARK: - Onboarding V1

    public func createInitial(_ draft: GroupDraft) async throws -> Group {
        // Sign-in-first architecture (post anon disable): the user must be
        // authenticated by the time the founder reaches the group step.
        // AuthGate gates onboarding behind a real session, and the
        // Supabase project has anonymous sign-ins disabled at the
        // provider level, so any "fall back to anon" retry would now
        // surface as `anonymous_provider_disabled` and confuse the
        // diagnosis. We let `create_group_with_admin` errors bubble up
        // so we see the real failure (auth, RLS, or RPC validation).
        struct Params: Encodable {
            let p_name: String
            let p_event_label: String
            let p_currency: String
            let p_timezone: String
            let p_base_template: String
            let p_cover_image_name: String?
        }
        let templateId = draft.template.isEmpty
            ? TemplateRegistry.dinnerRecurringId
            : draft.template
        let params = Params(
            p_name: draft.name,
            p_event_label: draft.resolvedVocabulary,
            p_currency: "MXN",
            p_timezone: "America/Mexico_City",
            p_base_template: templateId,
            p_cover_image_name: draft.coverImageName
        )

        do {
            return try await client
                .rpc("create_group_with_admin", params: params)
                .execute()
                .value
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateConfig(groupId: UUID, patch: GroupConfigPatch) async throws -> Group {
        struct Params: Encodable {
            let p_group_id: String
            let p_event_label: String?
            let p_frequency_type: String?
            let p_frequency_config: FrequencyConfig?
            let p_fines_enabled: Bool?
            let p_rotation_mode: String?
            let p_cover_image_name: String?
        }
        let params = Params(
            p_group_id: groupId.uuidString.lowercased(),
            p_event_label: patch.eventLabel,
            p_frequency_type: patch.frequencyType?.rawValue,
            p_frequency_config: patch.frequencyConfig,
            p_fines_enabled: patch.finesEnabled,
            p_rotation_mode: patch.rotationMode?.rawValue,
            p_cover_image_name: patch.coverImageName
        )
        do {
            let g: Group = try await client
                .rpc("update_group_config", params: params)
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateGovernance(groupId: UUID, rules: GovernanceRules) async throws -> Group {
        // Direct UPDATE on groups.governance jsonb. RLS policy
        // groups_update_admin gates this to founders / admins.
        struct Patch: Encodable {
            let governance: GovernanceRules
        }
        do {
            let g: Group = try await client
                .from("groups")
                .update(Patch(governance: rules))
                .eq("id", value: groupId.uuidString.lowercased())
                .select()
                .single()
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func fetchPreview(byInviteCode code: String) async throws -> InvitePreview {
        do {
            let preview: InvitePreview = try await client
                .from("invite_preview")
                .select("*")
                .eq("invite_code", value: code)
                .single()
                .execute()
                .value
            return preview
        } catch {
            throw GroupsError.inviteCodeNotFound
        }
    }

    // MARK: - F0 #4 (member management)

    public func setTurnOrder(groupId: UUID, userIds: [UUID]) async throws {
        struct Params: Encodable {
            let p_group_id: String
            let p_user_ids: [String]
        }
        do {
            _ = try await client
                .rpc(
                    "set_turn_order",
                    params: Params(
                        p_group_id: groupId.uuidString.lowercased(),
                        p_user_ids: userIds.map { $0.uuidString.lowercased() }
                    )
                )
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func removeMember(memberId: UUID) async throws {
        // RLS policy `members_delete` (00002) gates this: the caller must be
        // the same user (`user_id = auth.uid()`) OR a group admin. We don't
        // re-check role here; UI callers gate via GovernanceService first.
        do {
            try await client
                .from("group_members")
                .delete()
                .eq("id", value: memberId.uuidString.lowercased())
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    // MARK: - Primitives § 3 slice 3 (module write-path)

    public func setModule(groupId: UUID, slug: String, enabled: Bool) async throws -> Group {
        struct Params: Encodable {
            let p_group_id: String
            let p_module_slug: String
            let p_enabled: Bool
        }
        do {
            let g: Group = try await client
                .rpc(
                    "set_group_module",
                    params: Params(
                        p_group_id: groupId.uuidString.lowercased(),
                        p_module_slug: slug,
                        p_enabled: enabled
                    )
                )
                .execute()
                .value
            return g
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }
}
