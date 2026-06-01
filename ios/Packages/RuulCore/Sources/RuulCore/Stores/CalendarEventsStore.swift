import Foundation
import Observation

/// V3-D.23 — `@MainActor` store for the Calendar Event primitive.
/// Holds the upcoming list, an in-flight detail cache, and drives the
/// create + RSVP flows through draft state. Mutations refresh the
/// targeted slice so the UI reflects new state without a full reload.
@MainActor
@Observable
public final class CalendarEventsStore {

    public private(set) var events: [CalendarEventListItem] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    public private(set) var detail: CalendarEventDetail?
    public private(set) var detailPhase: StorePhase = .idle
    public private(set) var detailErrorMessage: String?

    /// V3 D.24 P12B-3 — single-RPC summary backing CalendarEventDetailView.
    /// View prefers this over `detail` for rendering counts + everything.
    /// No-throws: si falla, queda nil y la vista cae a `loadDetail` legacy.
    public private(set) var detailSummary: CalendarEventDetailSummary?
    public private(set) var detailSummaryPhase: StorePhase = .idle

    // MARK: - Draft state (Create sheet)

    public var isCreatePresented: Bool = false
    public var draftTitle: String = ""
    public var draftDescription: String = ""
    public var draftEventType: CalendarEventType = .social
    public var draftStartsAt: Date = CalendarEventsStore.defaultStartsAt()
    public var draftDuration: TimeInterval = 60 * 60 * 2  // 2h
    public var draftLocationName: String = ""
    public var draftRecurrence: CalendarEventRecurrenceKind = .none
    public var draftVisibility: CalendarEventVisibility = .group
    public private(set) var draftErrorMessage: String?

    // MARK: - Filters

    public var includeCancelled: Bool = false
    public var includeArchived: Bool = false

    private let repository: CanonicalCalendarEventsRepository

    public init(repository: CanonicalCalendarEventsRepository) {
        self.repository = repository
    }

    // MARK: - Load

    public func load(groupId: UUID) async {
        phase = .loading
        errorMessage = nil
        do {
            let from = Calendar.current.date(byAdding: .day, value: -1, to: Date())
            events = try await repository.listEvents(
                groupId: groupId,
                from: from,
                to: nil,
                includeCancelled: includeCancelled,
                includeArchived: includeArchived
            )
            phase = .loaded
        } catch {
            phase = .failed(message: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    public func refreshSilently(groupId: UUID) async {
        do {
            let from = Calendar.current.date(byAdding: .day, value: -1, to: Date())
            events = try await repository.listEvents(
                groupId: groupId,
                from: from,
                to: nil,
                includeCancelled: includeCancelled,
                includeArchived: includeArchived
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clear() {
        events = []
        phase = .idle
        errorMessage = nil
        detail = nil
        detailPhase = .idle
        detailErrorMessage = nil
        detailSummary = nil
        detailSummaryPhase = .idle
    }

    // MARK: - Detail

    public func loadDetail(eventId: UUID) async {
        detailPhase = .loading
        detailErrorMessage = nil
        do {
            detail = try await repository.detail(eventId: eventId)
            detailPhase = .loaded
        } catch {
            detailPhase = .failed(message: error.localizedDescription)
            detailErrorMessage = error.localizedDescription
        }
    }

    /// V3 D.24 P12B-3 — best-effort hydrate del read model
    /// `event_detail_summary`. NO throws: si falla, `detailSummary`
    /// queda nil y la vista cae a `loadDetail` legacy.
    public func loadSummary(eventId: UUID) async {
        if detailSummary?.event.id != eventId {
            detailSummary = nil
            detailSummaryPhase = .loading
        }
        do {
            detailSummary = try await repository.detailSummary(eventId: eventId)
            detailSummaryPhase = .loaded
        } catch {
            detailSummaryPhase = .failed(message: error.localizedDescription)
            // Intentionally NOT propagating to `detailErrorMessage`; the
            // legacy `loadDetail` path will surface its own error if needed.
        }
    }

    // MARK: - Draft helpers

    public func beginCreating() {
        draftTitle = ""
        draftDescription = ""
        draftEventType = .social
        draftStartsAt = CalendarEventsStore.defaultStartsAt()
        draftDuration = 60 * 60 * 2
        draftLocationName = ""
        draftRecurrence = .none
        draftVisibility = .group
        draftErrorMessage = nil
        isCreatePresented = true
    }

    public var canCreateDraft: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func saveDraft(groupId: UUID) async -> UUID? {
        draftErrorMessage = nil
        guard canCreateDraft else {
            draftErrorMessage = "Pon un título antes de guardar."
            return nil
        }
        let ends = draftStartsAt.addingTimeInterval(draftDuration)
        let rrule = draftRecurrence.rruleText(
            weekday: Calendar.current.component(.weekday, from: draftStartsAt)
        )
        do {
            let id = try await repository.create(
                groupId: groupId,
                title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                description: draftDescription,
                eventType: draftEventType,
                startsAt: draftStartsAt,
                endsAt: ends,
                timezone: TimeZone.current.identifier,
                locationName: draftLocationName,
                locationAddress: nil,
                locationUrl: nil,
                recurrenceRule: rrule,
                visibility: draftVisibility
            )
            isCreatePresented = false
            await refreshSilently(groupId: groupId)
            return id
        } catch {
            draftErrorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Mutations

    public func cancel(eventId: UUID, reason: String?, groupId: UUID) async {
        do {
            try await repository.cancel(eventId: eventId, reason: reason)
            await refreshSilently(groupId: groupId)
            await reloadDetailHydration(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func archive(eventId: UUID, groupId: UUID) async {
        do {
            try await repository.archive(eventId: eventId)
            await refreshSilently(groupId: groupId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func respond(
        eventId: UUID,
        status: CalendarEventRSVPStatus,
        note: String? = nil,
        groupId: UUID
    ) async {
        do {
            _ = try await repository.respond(eventId: eventId, status: status, note: note)
            await refreshSilently(groupId: groupId)
            await reloadDetailHydration(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addAttendee(
        eventId: UUID,
        membershipId: UUID?,
        invitedEmail: String?,
        displayName: String?,
        role: CalendarEventAttendeeRole = .attendee
    ) async {
        do {
            _ = try await repository.addAttendee(
                eventId: eventId,
                membershipId: membershipId,
                invitedEmail: invitedEmail,
                invitedPhone: nil,
                displayName: displayName,
                role: role
            )
            await reloadDetailHydration(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeAttendee(attendeeId: UUID, eventId: UUID) async {
        do {
            try await repository.removeAttendee(attendeeId: attendeeId)
            await reloadDetailHydration(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addReminder(eventId: UUID, offsetMinutes: Int) async {
        do {
            _ = try await repository.addReminder(eventId: eventId, offsetMinutes: offsetMinutes)
            await reloadDetailHydration(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeReminder(reminderId: UUID, eventId: UUID) async {
        do {
            try await repository.removeReminder(reminderId: reminderId)
            await reloadDetailHydration(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// V3 D.24 P12B-3 — recarga summary + detail tras cada mutación
    /// (cancel/respond/attendees/reminders). Mantiene ambos paths
    /// hidratados para que el view siga consistente en cualquier modo.
    private func reloadDetailHydration(eventId: UUID) async {
        await loadSummary(eventId: eventId)
        await loadDetail(eventId: eventId)
    }

    // MARK: - Derived state

    /// First 5 upcoming (status=scheduled, starts_at>=now) used by the
    /// GroupHome "Próximos eventos" cluster.
    public var upcoming: [CalendarEventListItem] {
        let now = Date()
        return events
            .filter { $0.status == .scheduled && $0.startsAt >= now }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Helpers

    private static func defaultStartsAt() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
        comps.hour = 20
        comps.minute = 0
        return cal.date(from: comps) ?? tomorrow
    }
}
