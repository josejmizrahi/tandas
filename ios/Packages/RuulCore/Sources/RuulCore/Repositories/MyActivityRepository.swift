import Foundation
import Supabase

/// A single cross-group activity entry from `my_activity_v1`.
public struct MyActivityItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let kind: Kind
    public let resourceId: UUID?
    public let groupId: UUID
    public let payload: JSONConfig
    public let occurredAt: Date

    public enum Kind: String, Sendable, Codable {
        case rsvp, checkIn = "check_in", voteCast = "vote_cast", ledger
    }
}

/// Cross-group user-scoped activity feed. Reads `my_activity_v1` (mig 00224).
public protocol MyActivityRepository: Actor {
    func loadRecent(limit: Int) async throws -> [MyActivityItem]
}

public actor MockMyActivityRepository: MyActivityRepository {
    public var items: [MyActivityItem]
    public init(seed: [MyActivityItem] = []) { self.items = seed }
    public func loadRecent(limit: Int) async throws -> [MyActivityItem] {
        Array(items.prefix(limit))
    }
}

public actor LiveMyActivityRepository: MyActivityRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    private struct Row: Decodable {
        let kind: String
        let id: UUID
        let resource_id: UUID?
        let user_id: UUID
        let group_id: UUID
        let payload: JSONConfig
        let occurred_at: Date
    }

    public func loadRecent(limit: Int) async throws -> [MyActivityItem] {
        let userId = try await client.auth.session.user.id
        let rows: [Row] = try await client
            .from("my_activity_v1")
            .select("kind, id, resource_id, user_id, group_id, payload, occurred_at")
            .eq("user_id", value: userId.uuidString.lowercased())
            .order("occurred_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.compactMap { row in
            guard let kind = MyActivityItem.Kind(rawValue: row.kind) else { return nil }
            return MyActivityItem(
                id: row.id,
                kind: kind,
                resourceId: row.resource_id,
                groupId: row.group_id,
                payload: row.payload,
                occurredAt: row.occurred_at
            )
        }
    }
}
