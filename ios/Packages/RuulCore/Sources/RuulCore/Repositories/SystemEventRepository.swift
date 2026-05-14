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

    /// Filtered + paginated query for the GroupHistoryView. All filter
    /// fields except `groupId` are optional. Returns chronological desc.
    func query(filter: SystemEventFilter, limit: Int, offset: Int) async throws -> [SystemEvent]
}

/// Search filter for the history view. `nil` fields = no constraint.
public struct SystemEventFilter: Sendable, Equatable, Hashable {
    public let groupId: UUID
    public var memberId: UUID?
    public var eventType: SystemEventType?
    public var resourceId: UUID?
    public var fromDate: Date?
    public var toDate: Date?

    public init(
        groupId: UUID,
        memberId: UUID? = nil,
        eventType: SystemEventType? = nil,
        resourceId: UUID? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil
    ) {
        self.groupId = groupId
        self.memberId = memberId
        self.eventType = eventType
        self.resourceId = resourceId
        self.fromDate = fromDate
        self.toDate = toDate
    }
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
            .filter { $0.groupId == groupId && !$0.eventType.isHiddenFromUserActivity }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    public func query(filter: SystemEventFilter, limit: Int, offset: Int) async throws -> [SystemEvent] {
        let filtered = emitted
            .filter { ev in
                guard ev.groupId == filter.groupId else { return false }
                // W2-D3: hide rule-fuel synthetic events from Activity.
                // If a caller explicitly filters BY a hidden type, honor
                // that — they're doing debug/admin work.
                if filter.eventType == nil && ev.eventType.isHiddenFromUserActivity {
                    return false
                }
                if let m = filter.memberId, ev.memberId != m { return false }
                if let t = filter.eventType, ev.eventType != t { return false }
                if let r = filter.resourceId, ev.resourceId != r { return false }
                if let from = filter.fromDate, ev.occurredAt < from { return false }
                if let to = filter.toDate, ev.occurredAt > to { return false }
                return true
            }
            .sorted { $0.occurredAt > $1.occurredAt }
        let start = min(offset, filtered.count)
        let end   = min(offset + limit, filtered.count)
        return Array(filtered[start..<end])
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
                p_event_type: eventType.rawString,
                p_resource_id: resourceId?.uuidString.lowercased(),
                p_member_id: memberId?.uuidString.lowercased(),
                p_payload: payload
            ))
            .execute()
            .value
        return id
    }

    public func recent(groupId: UUID, limit: Int) async throws -> [SystemEvent] {
        // W2-D3: filter rule-fuel synthetic events at the SQL layer.
        let hidden = SystemEventType.userHiddenActivityTypes.map(\.rawString)
        let hiddenList = "(" + hidden.joined(separator: ",") + ")"
        return try await client
            .from("system_events")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .not("event_type", operator: .in, value: hiddenList)
            .order("occurred_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    public func query(filter: SystemEventFilter, limit: Int, offset: Int) async throws -> [SystemEvent] {
        var q = client
            .from("system_events")
            .select("*")
            .eq("group_id", value: filter.groupId.uuidString.lowercased())
        if let m = filter.memberId {
            q = q.eq("member_id", value: m.uuidString.lowercased())
        }
        if let t = filter.eventType {
            q = q.eq("event_type", value: t.rawString)
        } else {
            // W2-D3: when the caller hasn't pinned an eventType, hide
            // rule-fuel synthetic events. Explicit filter by a hidden
            // type still works (debug/admin path).
            let hidden = SystemEventType.userHiddenActivityTypes.map(\.rawString)
            let hiddenList = "(" + hidden.joined(separator: ",") + ")"
            q = q.not("event_type", operator: .in, value: hiddenList)
        }
        if let r = filter.resourceId {
            q = q.eq("resource_id", value: r.uuidString.lowercased())
        }
        if let from = filter.fromDate {
            q = q.gte("occurred_at", value: ISO8601DateFormatter().string(from: from))
        }
        if let to = filter.toDate {
            q = q.lte("occurred_at", value: ISO8601DateFormatter().string(from: to))
        }
        return try await q
            .order("occurred_at", ascending: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
            .value
    }
}
