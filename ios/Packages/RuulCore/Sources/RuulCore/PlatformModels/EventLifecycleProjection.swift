import Foundation

/// One row of `public.event_lifecycle_view` (mig 00207). Atom-derived
/// projection per Plans/Active/EventResource.md §17: `is_live`, `is_past`,
/// `is_cancelled` are computed from `eventCancelled` + `eventClosed` atoms
/// plus the event's metadata clock (`starts_at` / `ends_at` /
/// `duration_minutes`).
///
/// This is the SPEC-COMPLIANT answer to "what state is this event in?".
/// `resources.status` still exists as the operational truth for legacy
/// readers; new code (rule engine, UI gating, analytics) should consume
/// this projection instead.
public struct EventLifecycleProjection: Projection, Codable, Sendable, Hashable {
    public static var projectionViewName: String { "event_lifecycle_view" }

    public let resourceId: UUID
    public let groupId: UUID
    public let startsAt: Date?
    public let endsAt: Date?

    /// Timestamp of the most recent `eventCancelled` atom. Nil = event
    /// has not been cancelled.
    public let cancelledAt: Date?
    /// User id (from atom payload) who cancelled. Nil when not cancelled.
    public let cancelledByUser: UUID?
    public let cancellationReason: String?

    /// Timestamp of the most recent `eventClosed` atom. Nil = event has
    /// not been closed via the lifecycle path.
    public let closedAt: Date?

    /// Timestamp of the most recent `eventStarted` atom (mig 00208).
    /// Nil when the cron has not yet emitted the atom (e.g. event hasn't
    /// started, or first cron tick after deploy). When present, this is
    /// the atom-authoritative answer to "when did this event start?".
    public let startedAt: Date?

    // Derived booleans (computed inside the view; do not mutate)
    public let isCancelled: Bool
    public let isClosed: Bool
    public let isLive: Bool
    public let isPast: Bool

    public enum CodingKeys: String, CodingKey {
        case resourceId         = "resource_id"
        case groupId            = "group_id"
        case startsAt           = "starts_at"
        case endsAt             = "ends_at"
        case cancelledAt        = "cancelled_at"
        case cancelledByUser    = "cancelled_by_user"
        case cancellationReason = "cancellation_reason"
        case closedAt           = "closed_at"
        case startedAt          = "started_at"
        case isCancelled        = "is_cancelled"
        case isClosed           = "is_closed"
        case isLive             = "is_live"
        case isPast             = "is_past"
    }
}
