import Foundation
import Supabase

/// Live `GroupsRepository` over Supabase. Extracted from
/// `GroupsRepository.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/04_repositories.md §3 — was the
/// only repo file >1000 LOC. The 3 actors that used to share one file
/// (protocol decl, MockGroupsRepository, LiveGroupsRepository) are now
/// 3 files.

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
        struct RoleRow: Decodable {
            let roles: [String]?
        }
        let row: RoleRow? = try? await client
            .from("group_members")
            .select("roles")
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        // V24.2 (mig 00303): role text column dropped. Derive a primary
        // role label from rawRoles for the legacy myRole field —
        // priority order matches what the dropped text column used to
        // carry (admin > founder > first known role > "member").
        let rawRoles = row?.roles ?? []
        let myRole: String =
            rawRoles.contains("admin")    ? "admin"   :
            rawRoles.contains("founder")  ? "founder" :
            rawRoles.first ?? "member"
        return GroupDetail(
            group: group,
            memberCount: countRow.first?.count ?? 1,
            myRole: myRole,
            myRawRoles: rawRoles
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

    /// Sprint F V26 fix: delegate to the canonical `leave_group` RPC
    /// (mig 00115) instead of the legacy direct UPDATE. The RPC emits
    /// the `memberLeft` atom server-side; the direct UPDATE silently
    /// skipped it. Kept as a thin wrapper for the existing protocol
    /// + callers (RootShellSheets, LeaveGroupConfirmationSheet).
    public func leave(_ id: UUID) async throws {
        try await leaveGroup(groupId: id)
    }

    public func members(of groupId: UUID) async throws -> [Member] {
        // V24.2 (mig 00303): role text column dropped — removed from SELECT.
        try await client
            .from("group_members")
            .select("id, group_id, user_id, display_name_override, roles, active, joined_at, left_at, joined_via, joined_via_invite_code")
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
            let name: String?
            let description: String?
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
                    name: patch.name,
                    description: patch.description,
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

    public func regenerateInviteCode(groupId: UUID) async throws -> String {
        struct Params: Encodable { let p_group_id: String }
        do {
            let new: String = try await client
                .rpc(
                    "regenerate_invite_code",
                    params: Params(p_group_id: groupId.uuidString.lowercased())
                )
                .execute()
                .value
            return new
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateAvatar(groupId: UUID, data: Data, contentType: String) async throws -> URL {
        let ext = Self.fileExtension(for: contentType)
        let ts = Int(Date.now.timeIntervalSince1970)
        let path = "\(groupId.uuidString.lowercased())/avatar-\(ts).\(ext)"

        do {
            _ = try await client.storage
                .from("group_avatars")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(
                        cacheControl: "3600",
                        contentType: contentType,
                        upsert: true
                    )
                )
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }

        let publicURL: URL
        do {
            publicURL = try client.storage.from("group_avatars").getPublicURL(path: path)
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }

        do {
            try await client
                .from("groups")
                .update(["avatar_url": publicURL.absoluteString])
                .eq("id", value: groupId.uuidString.lowercased())
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
        return publicURL
    }

    public func archive(groupId: UUID) async throws {
        struct Params: Encodable { let p_group_id: String }
        do {
            try await client
                .rpc("archive_group", params: Params(p_group_id: groupId.uuidString.lowercased()))
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func unarchive(groupId: UUID) async throws {
        struct Params: Encodable { let p_group_id: String }
        do {
            try await client
                .rpc("unarchive_group", params: Params(p_group_id: groupId.uuidString.lowercased()))
                .execute()
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    // MARK: - RolesV2 (Phase 5) live

    public func assignRole(groupId: UUID, userId: UUID, role: String) async throws -> Member {
        struct Params: Encodable {
            let p_group_id: String
            let p_user_id:  String
            let p_role:     String
        }
        do {
            return try await client
                .rpc(
                    "assign_role",
                    params: Params(
                        p_group_id: groupId.uuidString.lowercased(),
                        p_user_id:  userId.uuidString.lowercased(),
                        p_role:     role
                    )
                )
                .execute()
                .value
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func unassignRole(groupId: UUID, userId: UUID, role: String) async throws -> Member {
        struct Params: Encodable {
            let p_group_id: String
            let p_user_id:  String
            let p_role:     String
        }
        do {
            return try await client
                .rpc(
                    "unassign_role",
                    params: Params(
                        p_group_id: groupId.uuidString.lowercased(),
                        p_user_id:  userId.uuidString.lowercased(),
                        p_role:     role
                    )
                )
                .execute()
                .value
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func upsertGroupRole(
        groupId: UUID,
        roleId: String,
        label: String?,
        permissions: [Permission],
        maxHolders: Int?
    ) async throws -> Group {
        struct Params: Encodable {
            let p_group_id:    String
            let p_role_id:     String
            let p_label:       String?
            let p_permissions: [String]
            let p_max_holders: Int?
        }
        do {
            return try await client
                .rpc(
                    "upsert_group_role",
                    params: Params(
                        p_group_id:    groupId.uuidString.lowercased(),
                        p_role_id:     roleId,
                        p_label:       label,
                        p_permissions: permissions.map(\.rawString),
                        p_max_holders: maxHolders
                    )
                )
                .execute()
                .value
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    public func deleteGroupRole(groupId: UUID, roleId: String) async throws -> Group {
        struct Params: Encodable {
            let p_group_id: String
            let p_role_id:  String
        }
        do {
            return try await client
                .rpc(
                    "delete_group_role",
                    params: Params(
                        p_group_id: groupId.uuidString.lowercased(),
                        p_role_id:  roleId
                    )
                )
                .execute()
                .value
        } catch {
            throw GroupsError.rpcFailed(error.localizedDescription)
        }
    }

    private static func fileExtension(for contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/jpeg", "image/jpg":  return "jpg"
        case "image/png":                return "png"
        case "image/webp":               return "webp"
        case "image/heic":               return "heic"
        case "image/heif":               return "heif"
        default:                         return "jpg"
        }
    }
}
