import Foundation
import Supabase

/// Read + resolve user actions for the inbox. Sprint 1c renders these via
/// `ActionInboxView`. Inserts come from server-side rule executions, not
/// the client.
public protocol UserActionRepository: Actor {
    /// All pending (resolved_at IS NULL) actions for the current user,
    /// ordered by priority then chronologically.
    func pending(userId: UUID, groupId: UUID?) async throws -> [UserAction]

    /// Marks an action as resolved. Idempotent — already-resolved actions
    /// are no-ops.
    func resolve(actionId: UUID) async throws

    /// Cross-group pending counts: `{ groupId: count }`. Used by the home
    /// quick-switcher to badge each group chip with the user's pending
    /// load. RLS scopes to the caller's groups automatically.
    func pendingCountsByGroup(userId: UUID) async throws -> [UUID: Int]
}

// MARK: - Mock

public actor MockUserActionRepository: UserActionRepository {
    public private(set) var actions: [UserAction] = []

    public init(seed: [UserAction] = []) { self.actions = seed }

    public func pending(userId: UUID, groupId: UUID?) async throws -> [UserAction] {
        actions
            .filter { $0.userId == userId && $0.isPending }
            .filter { groupId == nil || $0.groupId == groupId! }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return priorityRank(lhs.priority) > priorityRank(rhs.priority)
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    public func resolve(actionId: UUID) async throws {
        guard let idx = actions.firstIndex(where: { $0.id == actionId }) else { return }
        let a = actions[idx]
        actions[idx] = UserAction(
            id: a.id,
            userId: a.userId,
            groupId: a.groupId,
            actionType: a.actionType,
            referenceId: a.referenceId,
            title: a.title,
            body: a.body,
            priority: a.priority,
            createdAt: a.createdAt,
            resolvedAt: .now
        )
    }

    public func pendingCountsByGroup(userId: UUID) async throws -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for action in actions where action.userId == userId && action.isPending {
            counts[action.groupId, default: 0] += 1
        }
        return counts
    }

    private func priorityRank(_ p: ActionPriority) -> Int {
        switch p {
        case .urgent: return 4
        case .high:   return 3
        case .medium: return 2
        case .low:    return 1
        }
    }
}

// MARK: - Live

public actor LiveUserActionRepository: UserActionRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func pending(userId: UUID, groupId: UUID?) async throws -> [UserAction] {
        var query = client
            .from("user_actions")
            .select("*")
            .eq("user_id", value: userId.uuidString.lowercased())
            .is("resolved_at", value: nil)
        if let groupId {
            query = query.eq("group_id", value: groupId.uuidString.lowercased())
        }
        return try await query
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func resolve(actionId: UUID) async throws {
        try await client
            .from("user_actions")
            .update(["resolved_at": ISO8601DateFormatter().string(from: .now)])
            .eq("id", value: actionId.uuidString.lowercased())
            .execute()
    }

    public func pendingCountsByGroup(userId: UUID) async throws -> [UUID: Int] {
        // Pull just the group_id column for pending rows; aggregate client-
        // side. Cheaper round-trip than a custom RPC for V1's expected
        // small action volume per user.
        struct Row: Decodable { let group_id: UUID }
        let rows: [Row] = try await client
            .from("user_actions")
            .select("group_id")
            .eq("user_id", value: userId.uuidString.lowercased())
            .is("resolved_at", value: nil)
            .execute()
            .value
        var counts: [UUID: Int] = [:]
        for row in rows {
            counts[row.group_id, default: 0] += 1
        }
        return counts
    }
}
