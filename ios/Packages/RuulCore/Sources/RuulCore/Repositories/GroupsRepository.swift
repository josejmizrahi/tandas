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
}

/// Partial update payload for the new bare-group config.
/// Post BigBang most settings live elsewhere (capability blocks, modules,
/// resource_series, governance jsonb), so this struct shrinks to the
/// fields that still belong on the bare Group.
public struct GroupConfigPatch: Sendable, Equatable {
    public var initialEventVocabulary: String?
    public var coverImageName: String?
    public var currency: String?
    public var timezone: String?

    public init(
        initialEventVocabulary: String? = nil,
        coverImageName: String? = nil,
        currency: String? = nil,
        timezone: String? = nil
    ) {
        self.initialEventVocabulary = initialEventVocabulary
        self.coverImageName = coverImageName
        self.currency = currency
        self.timezone = timezone
    }
}

// MARK: - Mock

public actor MockGroupsRepository: GroupsRepository {
    private var _groups: [Group]
    private var _members: [UUID: [Member]] = [:]
    private var _membersWithProfiles: [MemberWithProfile] = []
    public var nextCreateError: GroupsError?
    public var nextPreviewError: GroupsError?

    private let modules: ModuleRegistry

    public init(seed: [Group] = [], modules: ModuleRegistry = .v1Fallback) {
        self._groups = seed
        self.modules = modules
    }

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
        return GroupDetail(group: g, memberCount: _members[id]?.count ?? 1, myRole: "founder")
    }

    public func create(_ p: CreateGroupParams) async throws -> Group {
        var settings = GroupSettings()
        settings.eventVocabulary = p.initialEventVocabulary
        let g = Group(
            id: UUID(),
            name: p.name,
            description: p.description,
            currency: p.currency,
            timezone: p.timezone,
            inviteCode: String(UUID().uuidString.prefix(8)).lowercased(),
            coverImageName: p.coverImageName,
            baseTemplate: p.baseTemplate,
            settings: settings,
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
        var settings = GroupSettings()
        settings.eventVocabulary = draft.resolvedVocabulary
        let g = Group(
            id: UUID(),
            name: draft.name,
            inviteCode: String(UUID().uuidString.prefix(8)).lowercased(),
            coverImageName: draft.coverImageName,
            baseTemplate: draft.template.isEmpty ? nil : draft.template,
            settings: settings,
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
        var settings = g.settings ?? GroupSettings()
        if let v = patch.initialEventVocabulary { settings.eventVocabulary = v }
        let updated = Group(
            id: g.id,
            name: g.name,
            description: g.description,
            currency: patch.currency ?? g.currency,
            timezone: patch.timezone ?? g.timezone,
            inviteCode: g.inviteCode,
            coverImageName: patch.coverImageName ?? g.coverImageName,
            baseTemplate: g.baseTemplate,
            activeModules: g.activeModules,
            governance: g.governance,
            settings: settings,
            roles: g.roles,
            category: g.category,
            initials: g.initials,
            avatarUrl: g.avatarUrl,
            createdBy: g.createdBy,
            createdAt: g.createdAt,
            updatedAt: g.updatedAt
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
            id: g.id,
            name: g.name,
            description: g.description,
            currency: g.currency,
            timezone: g.timezone,
            inviteCode: g.inviteCode,
            coverImageName: g.coverImageName,
            baseTemplate: g.baseTemplate,
            activeModules: g.activeModules,
            governance: rules,
            settings: g.settings,
            roles: g.roles,
            category: g.category,
            initials: g.initials,
            avatarUrl: g.avatarUrl,
            createdBy: g.createdBy,
            createdAt: g.createdAt,
            updatedAt: g.updatedAt
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
            inviteCode: g.inviteCode,
            groupCreatedAt: g.createdAt,
            memberCount: _members[g.id]?.count ?? 1,
            recentMemberNames: nil
        )
    }

    // MARK: - Member management

    private var _turnOrders: [UUID: [UUID]] = [:]

    public func setTurnOrder(groupId: UUID, userIds: [UUID]) async throws {
        _turnOrders[groupId] = userIds
    }

    public func lastTurnOrder(for groupId: UUID) -> [UUID]? { _turnOrders[groupId] }

    public func removeMember(groupId: UUID, userId: UUID, reason: String?) async throws {
        _ = reason
        if var list = _members[groupId] {
            list.removeAll { $0.userId == userId }
            _members[groupId] = list
        }
        _membersWithProfiles.removeAll { $0.member.userId == userId && $0.member.groupId == groupId }
    }

    public func leaveGroup(groupId: UUID) async throws {
        // Mock fixture doesn't track auth.uid — the test driving the
        // mock supplies the user_id externally. Treat as a no-op so
        // unit tests focused on UI flows can call leaveGroup without
        // requiring a fully wired auth context.
        _ = groupId
    }

    // MARK: - Module lifecycle

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
        let updated = Group(
            id: g.id,
            name: g.name,
            description: g.description,
            currency: g.currency,
            timezone: g.timezone,
            inviteCode: g.inviteCode,
            coverImageName: g.coverImageName,
            baseTemplate: g.baseTemplate,
            activeModules: modules,
            governance: g.governance,
            settings: g.settings,
            roles: g.roles,
            category: g.category,
            initials: g.initials,
            avatarUrl: g.avatarUrl,
            createdBy: g.createdBy,
            createdAt: g.createdAt,
            updatedAt: g.updatedAt
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
        struct Params: Encodable {
            let p_name: String
            let p_description: String?
            let p_currency: String
            let p_timezone: String
            let p_base_template: String?
            let p_cover_image_name: String?
            let p_initial_event_vocabulary: String?
        }
        let params = Params(
            p_name: p.name,
            p_description: p.description,
            p_currency: p.currency,
            p_timezone: p.timezone ?? "America/Mexico_City",
            p_base_template: p.baseTemplate,
            p_cover_image_name: p.coverImageName,
            p_initial_event_vocabulary: p.initialEventVocabulary
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

    public func createInitial(_ draft: GroupDraft) async throws -> Group {
        let params = CreateGroupParams(
            name: draft.name,
            description: nil,
            currency: "MXN",
            timezone: "America/Mexico_City",
            baseTemplate: draft.template.isEmpty ? nil : draft.template,
            coverImageName: draft.coverImageName,
            initialEventVocabulary: draft.resolvedVocabulary
        )
        return try await create(params)
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

    public func updateConfig(groupId: UUID, patch: GroupConfigPatch) async throws -> Group {
        // Direct UPDATE on bare-group fields. Post BigBang there is no
        // update_group_config RPC — those flat-column fields are gone. The
        // remaining settings (vocabulary, currency, timezone, cover image)
        // patch via PostgREST update. RLS gates by admin via groups_update.
        struct Patch: Encodable {
            let cover_image_name: String?
            let currency: String?
            let timezone: String?
            let settings: GroupSettings?
        }
        var settings: GroupSettings? = nil
        if let v = patch.initialEventVocabulary {
            var s = GroupSettings()
            s.eventVocabulary = v
            settings = s
        }
        do {
            let g: Group = try await client
                .from("groups")
                .update(Patch(
                    cover_image_name: patch.coverImageName,
                    currency: patch.currency,
                    timezone: patch.timezone,
                    settings: settings
                ))
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

    public func updateGovernance(groupId: UUID, rules: GovernanceRules) async throws -> Group {
        struct Patch: Encodable { let governance: GovernanceRules }
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

    public func removeMember(groupId: UUID, userId: UUID, reason: String?) async throws {
        struct Params: Encodable {
            let p_group_id: String
            let p_user_id: String
            let p_reason: String?
        }
        do {
            _ = try await client
                .rpc(
                    "remove_member",
                    params: Params(
                        p_group_id: groupId.uuidString.lowercased(),
                        p_user_id:  userId.uuidString.lowercased(),
                        p_reason:   reason
                    )
                )
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func leaveGroup(groupId: UUID) async throws {
        struct Params: Encodable { let p_group_id: String }
        do {
            _ = try await client
                .rpc(
                    "leave_group",
                    params: Params(p_group_id: groupId.uuidString.lowercased())
                )
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

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
