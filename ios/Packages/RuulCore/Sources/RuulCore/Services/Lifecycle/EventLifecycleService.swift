import Foundation
import OSLog

/// Coordinates event status transitions.
///
/// Post BigBang: recurrence lives on `ResourceSeries` (Phase 2 — not yet
/// implemented in iOS). This service no longer owns recurrence/auto-
/// generate logic. It is reduced to event close transitions and exists
/// as a stable injection point for callers (Coordinators) until the
/// ResourceSeries model + its lifecycle service ship.
@MainActor
public final class EventLifecycleService {
    private let eventRepo: any EventRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.lifecycle")

    public init(eventRepo: any EventRepository) {
        self.eventRepo = eventRepo
    }

    /// Closes the event without firing the rule engine (V1 behaviour).
    /// Recurrence cascade is removed — Phase 2 will reintroduce it via
    /// ResourceSeries.generateNextOccurrence.
    public func closeEvent(_ event: Event, in group: Group, autoGenerateEnabled: Bool) async throws -> Event {
        try await eventRepo.closeEvent(event.id)
    }

    /// Reverses close/cancel. Permission gate (host or manageEvents) is
    /// server-enforced via `reopen_event` RPC (mig 00295). Idempotent on
    /// already-open events.
    public func reopenEvent(_ event: Event, in group: Group) async throws -> Event {
        try await eventRepo.reopenEvent(event.id)
    }

    /// Phase 2 placeholder — generating siblings will move to a
    /// ResourceSeries-aware service. For now this is a no-op so legacy
    /// coordinators compile during the rewrite.
    public func generateInitialBatch(after firstDraft: EventDraft, count: Int, group: Group) async throws -> [Event] {
        []
    }

    /// Phase 2 placeholder — auto-generate is a property of the
    /// `recurrence` capability block on a ResourceSeries, not a flat
    /// group toggle. No-op until that lands.
    public func setAutoGenerate(_ enabled: Bool, group: Group) async throws {
        // Intentionally empty.
    }
}
