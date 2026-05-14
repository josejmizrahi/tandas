import Foundation
import Supabase
import OSLog

/// Real-time subscription for a specific event resource. Watches the
/// `rsvp_actions` and `check_in_actions` atoms (mig 00153/00154) and
/// emits a kick whenever a row for this resource lands. The consumer
/// (EventDetailCoordinator) refetches its RSVP list from
/// `attendance_view` on each kick.
///
/// Why a kick instead of a typed payload
/// =====================================
/// Pre-mig 00159, `RSVPRealtimeService` subscribed to `event_attendance`
/// and decoded each row directly into `RSVP`. Mig 00159 dropped that
/// table — the canonical RSVP truth now lives split across two atoms
/// (`rsvp_actions` for status changes, `check_in_actions` for arrival)
/// and is folded back via the `attendance_view` projection. There's no
/// single atom row shape that maps 1:1 to `RSVP`, so the realtime layer
/// emits invalidation kicks instead. Consumer refetches the merged
/// view shape — same pattern as `MultiDeviceChangeFeed` (W3 E-3.1).
///
/// Lifecycle
/// =========
/// - Caller `init` with the active event id (which is the resource_id
///   for events post-mig 00159).
/// - Caller observes `changes` (AsyncStream) and `await subscribe()`.
/// - On view disappear, caller `await unsubscribe()`.
///
/// Falls back to a no-op stream if Realtime isn't available — clients
/// still work via manual refresh + optimistic updates.
public actor RSVPRealtimeService {
    public enum Change: Sendable {
        /// Something in this event's RSVP / check-in atoms changed.
        /// Consumer refetches the attendance projection.
        case kick
    }

    private let client: SupabaseClient
    private let eventId: UUID
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rsvp.realtime")

    private var rsvpChannel: RealtimeChannelV2?
    private var checkInChannel: RealtimeChannelV2?
    private var consumerTasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<Change>.Continuation?
    public nonisolated let changes: AsyncStream<Change>

    public init(client: SupabaseClient, eventId: UUID) {
        self.client = client
        self.eventId = eventId
        var localContinuation: AsyncStream<Change>.Continuation!
        self.changes = AsyncStream { c in localContinuation = c }
        Task { await self.setContinuation(localContinuation) }
    }

    private func setContinuation(_ c: AsyncStream<Change>.Continuation) {
        self.continuation = c
    }

    public func subscribe() async {
        guard rsvpChannel == nil else { return }
        rsvpChannel    = await openChannel(table: "rsvp_actions",     name: "rsvp-\(eventId.uuidString)")
        checkInChannel = await openChannel(table: "check_in_actions", name: "checkin-\(eventId.uuidString)")
    }

    public func unsubscribe() async {
        for task in consumerTasks { task.cancel() }
        consumerTasks.removeAll()
        await rsvpChannel?.unsubscribe()
        await checkInChannel?.unsubscribe()
        rsvpChannel = nil
        checkInChannel = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Channel plumbing

    private func openChannel(table: String, name: String) async -> RealtimeChannelV2 {
        let channel = client.realtimeV2.channel(name)
        let filter = "resource_id=eq.\(eventId.uuidString.lowercased())"

        // Atoms are append-only (guarded by mig 00103), so only INSERT
        // events are meaningful. Subscribing to update/delete is harmless
        // but would never fire under normal operation.
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: table,
            filter: filter
        )

        consumerTasks.append(Task { [weak self] in
            for await _ in inserts {
                guard let self else { return }
                await self.kick()
            }
        })

        await channel.subscribe()
        return channel
    }

    private func kick() async {
        continuation?.yield(.kick)
    }
}
