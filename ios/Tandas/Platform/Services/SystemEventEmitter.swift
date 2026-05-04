import Foundation

/// Convenience wrapper around `SystemEventRepository`. Sprint 1b/1c flows
/// call `await emitter.emit(.eventClosed, group: ..., resource: ...)`
/// instead of constructing the RPC params directly.
///
/// Idiomatic usage:
///
///     await emitter.emit(
///         .eventClosed,
///         groupId: event.groupId,
///         resourceId: event.id,
///         memberId: nil,
///         payload: ["closed_by": .string(userId.uuidString)]
///     )
///
/// Errors are intentionally swallowed and logged — emitting a system event
/// must never block the user-facing flow that produced it. The cron edge
/// function will eventually pick up retries via the failed-emit dead-letter
/// table (Fase posterior).
public actor SystemEventEmitter {
    private let repository: any SystemEventRepository

    public init(repository: any SystemEventRepository) {
        self.repository = repository
    }

    @discardableResult
    public func emit(
        _ eventType: SystemEventType,
        groupId: UUID,
        resourceId: UUID? = nil,
        memberId: UUID? = nil,
        payload: JSONConfig = .empty
    ) async -> UUID? {
        do {
            return try await repository.emit(
                groupId: groupId,
                eventType: eventType,
                resourceId: resourceId,
                memberId: memberId,
                payload: payload
            )
        } catch {
            // Intentionally non-throwing: emit failures must never break
            // user-facing flows. Future: enqueue to a local SwiftData
            // outbox + retry on next app launch.
            return nil
        }
    }
}
