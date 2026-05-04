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
}
