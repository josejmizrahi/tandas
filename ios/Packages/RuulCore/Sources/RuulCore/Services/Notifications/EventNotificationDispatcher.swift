import Foundation
import Supabase

/// Errors surfaced by `EventNotificationDispatcher` implementations.
public enum EventNotificationDispatchError: Error, Equatable {
    /// Caller hit the per-event rate limit. `nextAvailableAt` is the
    /// absolute Date at which a fresh send would be accepted.
    case rateLimited(nextAvailableAt: Date)
    /// Underlying Supabase function call failed (non-2xx, decoding error,
    /// network drop). Message is the underlying `localizedDescription`,
    /// suitable for logging — not for user copy.
    case edgeFailure(String)
}

/// Triggers event-lifecycle pushes (host reminders, deadline warnings, …)
/// through the `send-event-notification` edge function. The edge fn
/// resolves recipients server-side (per-kind logic) and writes one row
/// per recipient to `notifications_outbox`. Actual APNs delivery is the
/// `dispatch-notifications` cron's job (out-of-band).
///
/// Implementations enforce a per-event client-side rate limit (Beta 1
/// W1 D-1.1) so a host hammering the "Recordar a pendientes" button only
/// fires the underlying RPC once per window.
public protocol EventNotificationDispatcher: Actor {
    /// Triggers a `host_reminder` push for `eventId`. Returns the
    /// outbox row count the edge fn wrote (= recipients with a pending
    /// RSVP). Throws `.rateLimited(nextAvailableAt:)` when the caller
    /// is inside the per-event window, or `.edgeFailure(_)` when the
    /// underlying invocation fails.
    func sendHostReminder(eventId: UUID) async throws -> Int
}

// MARK: - Mock

/// In-memory dispatcher for previews + tests. Records every invocation
/// and skips rate-limiting so tests aren't time-sensitive.
public actor MockEventNotificationDispatcher: EventNotificationDispatcher {
    public private(set) var sent: [UUID] = []
    public let stubResponseCount: Int

    public init(stubResponseCount: Int = 1) {
        self.stubResponseCount = stubResponseCount
    }

    public func sendHostReminder(eventId: UUID) async throws -> Int {
        sent.append(eventId)
        return stubResponseCount
    }
}

// MARK: - Live

/// Production dispatcher backed by the Supabase functions client.
/// In-memory `lastSentByEvent` tracks the per-event window; no
/// persistence across app restarts (rate-limit is purely a tap-spam
/// guard, not a long-horizon policy).
public actor LiveEventNotificationDispatcher: EventNotificationDispatcher {
    /// Window per event. 30 min matches the Beta 1 W1 D-1.1 spec —
    /// long enough that hosts don't double-blast pending guests, short
    /// enough that genuine "yo otra vez, urgente" still gets through
    /// after a half-hour pause.
    public static let rateLimitWindow: TimeInterval = 30 * 60

    private let client: SupabaseClient
    private var lastSentByEvent: [UUID: Date] = [:]

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func sendHostReminder(eventId: UUID) async throws -> Int {
        if let last = lastSentByEvent[eventId] {
            let nextAt = last.addingTimeInterval(Self.rateLimitWindow)
            if nextAt > .now {
                throw EventNotificationDispatchError.rateLimited(nextAvailableAt: nextAt)
            }
        }

        struct Body: Encodable {
            let event_id: String
            let kind: String
        }
        struct Response: Decodable {
            let outbox_count: Int
        }

        do {
            let resp: Response = try await client.functions.invoke(
                "send-event-notification",
                options: FunctionInvokeOptions(body: Body(
                    event_id: eventId.uuidString.lowercased(),
                    kind: "host_reminder"
                ))
            )
            lastSentByEvent[eventId] = .now
            return resp.outbox_count
        } catch {
            throw EventNotificationDispatchError.edgeFailure(error.localizedDescription)
        }
    }
}
