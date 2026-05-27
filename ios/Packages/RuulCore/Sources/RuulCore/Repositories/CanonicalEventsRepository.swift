import Foundation

/// Foundation-scope repository for Primitiva 13 (Memoria). Reads via
/// `group_events_recent(...)`. Write path stays at the backend RPCs —
/// every canonical mutation already writes to `group_events` via
/// `record_system_event`; iOS only reads.
public struct CanonicalEventsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func recentEvents(
        groupId: UUID,
        limit: Int = 100,
        before: Date? = nil
    ) async throws -> [GroupEvent] {
        try await rpc.groupEventsRecent(groupId: groupId, limit: limit, before: before)
    }
}
