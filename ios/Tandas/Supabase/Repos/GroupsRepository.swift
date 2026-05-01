import Foundation
import Supabase

enum GroupsError: Error, Equatable {
    case inviteCodeNotFound
    case rpcFailed(String)
    case notFound
}

protocol GroupsRepository: Actor {
    func listMine() async throws -> [Group]
    func get(_ id: UUID) async throws -> GroupDetail
    func create(_ params: CreateGroupParams) async throws -> Group
    func joinByCode(_ code: String) async throws -> Group
    func leave(_ id: UUID) async throws
    func members(of groupId: UUID) async throws -> [Member]
}

// MARK: - Mock

actor MockGroupsRepository: GroupsRepository {
    private var _groups: [Group]
    private var _members: [UUID: [Member]] = [:]

    init(seed: [Group] = []) { self._groups = seed }

    func listMine() async throws -> [Group] { _groups }

    func get(_ id: UUID) async throws -> GroupDetail {
        guard let g = _groups.first(where: { $0.id == id }) else { throw GroupsError.notFound }
        return GroupDetail(group: g, memberCount: _members[id]?.count ?? 1, myRole: "admin")
    }

    func create(_ p: CreateGroupParams) async throws -> Group {
        let g = Group(
            id: UUID(), name: p.name, description: p.description,
            groupType: p.groupType,
            inviteCode: String(UUID().uuidString.prefix(8)).lowercased(),
            createdAt: .now
        )
        _groups.append(g)
        return g
    }

    func joinByCode(_ code: String) async throws -> Group {
        guard let g = _groups.first(where: { $0.inviteCode == code }) else {
            throw GroupsError.inviteCodeNotFound
        }
        return g
    }

    func leave(_ id: UUID) async throws {
        _groups.removeAll { $0.id == id }
    }

    func members(of groupId: UUID) async throws -> [Member] {
        _members[groupId] ?? []
    }
}

// MARK: - Live

actor LiveGroupsRepository: GroupsRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listMine() async throws -> [Group] {
        let userId = try await client.auth.session.user.id
        struct Row: Decodable { let groups: Group }
        let rows: [Row] = try await client
            .from("group_members")
            .select("groups(id, name, description, group_type, invite_code, created_at)")
            .eq("user_id", value: userId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
        return rows.map(\.groups)
    }

    func get(_ id: UUID) async throws -> GroupDetail {
        let group: Group = try await client
            .from("groups")
            .select("id, name, description, group_type, invite_code, created_at")
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

    func create(_ p: CreateGroupParams) async throws -> Group {
        struct Params: Encodable {
            let p_name: String
            let p_description: String?
            let p_event_label: String
            let p_currency: String
            let p_timezone: String
            let p_default_day: Int?
            let p_default_time: String?
            let p_default_location: String?
            let p_voting_threshold: Double
            let p_voting_quorum: Double
            let p_fund_enabled: Bool
            let p_group_type: String
        }
        let params = Params(
            p_name: p.name,
            p_description: p.description,
            p_event_label: p.eventLabel,
            p_currency: p.currency,
            p_timezone: "America/Mexico_City",
            p_default_day: p.defaultDayOfWeek,
            p_default_time: p.defaultStartTime,
            p_default_location: p.defaultLocation,
            p_voting_threshold: 0.5,
            p_voting_quorum: 0.5,
            p_fund_enabled: true,
            p_group_type: p.groupType.rawValue
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

    func joinByCode(_ code: String) async throws -> Group {
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

    func leave(_ id: UUID) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("group_members")
            .update(["active": false])
            .eq("group_id", value: id.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
    }

    func members(of groupId: UUID) async throws -> [Member] {
        try await client
            .from("group_members")
            .select("id, group_id, user_id, display_name_override, role, active, joined_at")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("active", value: true)
            .execute()
            .value
    }
}
