import Foundation
import Supabase

/// In-memory mock for `GroupsRepository`. Drives previews + unit tests
/// without round-tripping to Supabase. Extracted from
/// `GroupsRepository.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/04_repositories.md §3 — was the
/// only repo file >1000 LOC. The 3 actors that used to share one file
/// (protocol decl, MockGroupsRepository, LiveGroupsRepository) are now
/// 3 files.

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
        return GroupDetail(
            group: g,
            memberCount: _members[id]?.count ?? 1,
            myRole: "founder",
            myRawRoles: ["founder", "member"]
        )
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
            name: patch.name ?? g.name,
            description: patch.description ?? g.description,
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

    public func updateAvatar(groupId: UUID, data: Data, contentType: String) async throws -> URL {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let url = URL(string: "https://example.test/group_avatars/\(groupId.uuidString.lowercased()).jpg")!
        let g = _groups[idx]
        _groups[idx] = Group(
            id: g.id, name: g.name, description: g.description,
            currency: g.currency, timezone: g.timezone, inviteCode: g.inviteCode,
            coverImageName: g.coverImageName, baseTemplate: g.baseTemplate,
            activeModules: g.activeModules, governance: g.governance,
            settings: g.settings, roles: g.roles, category: g.category,
            initials: g.initials, avatarUrl: url.absoluteString,
            createdBy: g.createdBy, createdAt: g.createdAt, updatedAt: g.updatedAt,
            archivedAt: g.archivedAt
        )
        return url
    }

    public func archive(groupId: UUID) async throws {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let g = _groups[idx]
        _groups[idx] = Group(
            id: g.id, name: g.name, description: g.description,
            currency: g.currency, timezone: g.timezone, inviteCode: g.inviteCode,
            coverImageName: g.coverImageName, baseTemplate: g.baseTemplate,
            activeModules: g.activeModules, governance: g.governance,
            settings: g.settings, roles: g.roles, category: g.category,
            initials: g.initials, avatarUrl: g.avatarUrl,
            createdBy: g.createdBy, createdAt: g.createdAt, updatedAt: g.updatedAt,
            archivedAt: .now
        )
    }

    public func unarchive(groupId: UUID) async throws {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let g = _groups[idx]
        _groups[idx] = Group(
            id: g.id, name: g.name, description: g.description,
            currency: g.currency, timezone: g.timezone, inviteCode: g.inviteCode,
            coverImageName: g.coverImageName, baseTemplate: g.baseTemplate,
            activeModules: g.activeModules, governance: g.governance,
            settings: g.settings, roles: g.roles, category: g.category,
            initials: g.initials, avatarUrl: g.avatarUrl,
            createdBy: g.createdBy, createdAt: g.createdAt, updatedAt: g.updatedAt,
            archivedAt: nil
        )
    }

    public func regenerateInviteCode(groupId: UUID) async throws -> String {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let new = String(UUID().uuidString.prefix(8)).lowercased()
        let g = _groups[idx]
        _groups[idx] = Group(
            id: g.id,
            name: g.name,
            description: g.description,
            currency: g.currency,
            timezone: g.timezone,
            inviteCode: new,
            coverImageName: g.coverImageName,
            baseTemplate: g.baseTemplate,
            activeModules: g.effectiveActiveModules,
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
        return new
    }

    // MARK: - RolesV2 (Phase 5) mock

    public func assignRole(groupId: UUID, userId: UUID, role: String) async throws -> Member {
        try mutateMemberRoles(groupId: groupId, userId: userId) { current in
            current.contains(role) ? current : current + [role]
        }
    }

    public func unassignRole(groupId: UUID, userId: UUID, role: String) async throws -> Member {
        if role == "member" {
            throw GroupsError.rpcFailed("cannot remove system role \"member\"")
        }
        return try mutateMemberRoles(groupId: groupId, userId: userId) { current in
            current.filter { $0 != role }
        }
    }

    public func upsertGroupRole(
        groupId: UUID,
        roleId: String,
        label: String?,
        permissions: [Permission],
        maxHolders: Int?
    ) async throws -> Group {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let normalized = roleId.lowercased()
        let isSystem = ["founder", "member"].contains(normalized)
        if normalized == "founder", !permissions.contains(.assignRoles) {
            throw GroupsError.rpcFailed("founder must retain assignRoles")
        }
        var catalog = _groups[idx].roles ?? RoleDefinition.v1SystemRoles
        catalog[normalized] = RoleDefinition(
            id: normalized,
            label: label?.isEmpty == true ? nil : label,
            permissions: Array(Set(permissions)).sorted { $0.rawString < $1.rawString },
            maxHolders: maxHolders,
            system: isSystem
        )
        _groups[idx] = withCatalog(_groups[idx], roles: catalog)
        return _groups[idx]
    }

    public func deleteGroupRole(groupId: UUID, roleId: String) async throws -> Group {
        guard let idx = _groups.firstIndex(where: { $0.id == groupId }) else {
            throw GroupsError.notFound
        }
        let normalized = roleId.lowercased()
        if ["founder", "member"].contains(normalized) {
            throw GroupsError.rpcFailed("cannot delete system role \(normalized)")
        }
        var catalog = _groups[idx].roles ?? [:]
        catalog.removeValue(forKey: normalized)
        _groups[idx] = withCatalog(_groups[idx], roles: catalog)

        if var list = _members[groupId] {
            list = list.map { stripRoleFromMember($0, role: normalized) }
            _members[groupId] = list
        }
        _membersWithProfiles = _membersWithProfiles.map { mw in
            guard mw.member.groupId == groupId else { return mw }
            return MemberWithProfile(member: stripRoleFromMember(mw.member, role: normalized), profile: mw.profile)
        }
        return _groups[idx]
    }

    // MARK: helpers

    private func mutateMemberRoles(
        groupId: UUID,
        userId: UUID,
        transform: ([String]) -> [String]
    ) throws -> Member {
        var found: Member?
        if var list = _members[groupId] {
            if let mIdx = list.firstIndex(where: { $0.userId == userId }) {
                let updated = withRoles(list[mIdx], roles: transform(list[mIdx].rawRoles))
                list[mIdx] = updated
                _members[groupId] = list
                found = updated
            }
        }
        if let idx = _membersWithProfiles.firstIndex(where: { $0.member.groupId == groupId && $0.member.userId == userId }) {
            let updated = withRoles(_membersWithProfiles[idx].member, roles: transform(_membersWithProfiles[idx].member.rawRoles))
            _membersWithProfiles[idx] = MemberWithProfile(member: updated, profile: _membersWithProfiles[idx].profile)
            found = updated
        }
        guard let result = found else { throw GroupsError.notFound }
        return result
    }

    private func withRoles(_ m: Member, roles: [String]) -> Member {
        Member(
            id: m.id,
            groupId: m.groupId,
            userId: m.userId,
            displayNameOverride: m.displayNameOverride,
            roles: roles.compactMap(MemberRole.init(rawValue:)),
            rawRoles: roles,
            active: m.active,
            joinedAt: m.joinedAt,
            leftAt: m.leftAt,
            joinedVia: m.joinedVia,
            joinedViaInviteCode: m.joinedViaInviteCode
        )
    }

    private func stripRoleFromMember(_ m: Member, role: String) -> Member {
        guard m.rawRoles.contains(role) else { return m }
        return withRoles(m, roles: m.rawRoles.filter { $0 != role })
    }

    private func withCatalog(_ g: Group, roles: [String: RoleDefinition]) -> Group {
        Group(
            id: g.id,
            name: g.name,
            description: g.description,
            currency: g.currency,
            timezone: g.timezone,
            inviteCode: g.inviteCode,
            coverImageName: g.coverImageName,
            baseTemplate: g.baseTemplate,
            activeModules: g.activeModules,
            governance: g.governance,
            settings: g.settings,
            roles: roles,
            category: g.category,
            initials: g.initials,
            avatarUrl: g.avatarUrl,
            createdBy: g.createdBy,
            createdAt: g.createdAt,
            updatedAt: .now,
            archivedAt: g.archivedAt
        )
    }
}
