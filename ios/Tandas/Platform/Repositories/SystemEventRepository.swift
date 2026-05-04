import Foundation
import Supabase

/// Read + emit system events. Sprint 1a uses this from the Swift side only
/// to EMIT events (via `record_system_event` RPC); the rule engine runs
/// server-side in `process-system-events` edge function.
///
/// Reads are exposed for future debug / inbox screens that want to display
/// "what happened" timelines.
public protocol SystemEventRepository: Actor {
    /// Inserts a system event via the `record_system_event` RPC. Returns
    /// the new event id.
    func emit(
        groupId: UUID,
        eventType: SystemEventType,
        resourceId: UUID?,
        memberId: UUID?,
        payload: JSONConfig
    ) async throws -> UUID

    /// Lists recent system events for a group (chronological desc).
    func recent(groupId: UUID, limit: Int) async throws -> [SystemEvent]
}

// MARK: - Mock

public actor MockSystemEventRepository: SystemEventRepository {
    public private(set) var emitted: [SystemEvent] = []
    public var nextEmitError: Error?

    public init() {}

    public func emit(
        groupId: UUID,
        eventType: SystemEventType,
        resourceId: UUID?,
        memberId: UUID?,
        payload: JSONConfig
    ) async throws -> UUID {
        if let err = nextEmitError { nextEmitError = nil; throw err }
        let event = SystemEvent(
            groupId: groupId,
            eventType: eventType,
            resourceId: resourceId,
            memberId: memberId,
            payload: payload
        )
        emitted.append(event)
        return event.id
    }

    public func recent(groupId: UUID, limit: Int) async throws -> [SystemEvent] {
        emitted
            .filter { $0.groupId == groupId }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Live

public actor LiveSystemEventRepository: SystemEventRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func emit(
        groupId: UUID,
        eventType: SystemEventType,
        resourceId: UUID?,
        memberId: UUID?,
        payload: JSONConfig
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_group_id: String
            let p_event_type: String
            let p_resource_id: String?
            let p_member_id: String?
            let p_payload: JSONConfig
        }
        let id: UUID = try await client
            .rpc("record_system_event", params: Params(
                p_group_id: groupId.uuidString.lowercased(),
                p_event_type: eventType.rawValue,
                p_resource_id: resourceId?.uuidString.lowercased(),
                p_member_id: memberId?.uuidString.lowercased(),
                p_payload: payload
            ))
            .execute()
            .value
        return id
    }

    public func recent(groupId: UUID, limit: Int) async throws -> [SystemEvent] {
        try await client
            .from("system_events")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("occurred_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }
}
