import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class EventDetailCoordinator {
    public enum ViewerRole: Sendable, Hashable { case host, guestRole }

    public private(set) var event: Event
    public private(set) var rsvps: [RSVP] = []
    public private(set) var myRSVP: RSVP?
    public private(set) var isLoading: Bool = false
    public private(set) var isMutating: Bool = false
    public private(set) var error: CoordinatorError?
    /// True only for the initial load case (no event data yet + error set).
    /// `EventDetailHost` swaps the loading view for an inline error state
    /// when this flag flips on; mid-flight errors (RSVP, check-in) keep
    /// the detail visible and the existing alert/toast pathway handles
    /// the surface.
    public var hasInitialLoadError: Bool { error != nil && rsvps.isEmpty && myRSVP == nil }

    public let viewerRole: ViewerRole
    public let group: Group
    private let userId: UUID
    private let eventRepo: any EventRepository
    private let rsvpRepo: any RSVPRepository
    private let checkInRepo: any CheckInRepository
    private let lifecycle: EventLifecycleService
    private let notifications: NotificationService?
    private let notificationDispatcher: (any EventNotificationDispatcher)?
    public let walletService: any WalletPassService
    private let analytics: EventAnalytics
    private let realtimeFactory: ((UUID) -> RSVPRealtimeService)?
    private let systemEvents: SystemEventEmitter?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.detail")

    public init(
        event: Event,
        group: Group,
        userId: UUID,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository,
        checkInRepo: any CheckInRepository,
        lifecycle: EventLifecycleService,
        notifications: NotificationService?,
        walletService: any WalletPassService,
        analytics: EventAnalytics,
        realtimeFactory: ((UUID) -> RSVPRealtimeService)? = nil,
        systemEvents: SystemEventEmitter? = nil,
        notificationDispatcher: (any EventNotificationDispatcher)? = nil
    ) {
        self.event = event
        self.group = group
        self.userId = userId
        self.viewerRole = (event.hostId == userId) ? .host : .guestRole
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
        self.checkInRepo = checkInRepo
        self.lifecycle = lifecycle
        self.notifications = notifications
        self.notificationDispatcher = notificationDispatcher
        self.walletService = walletService
        self.analytics = analytics
        self.realtimeFactory = realtimeFactory
        self.systemEvents = systemEvents
        Task {
            await analytics.eventView(eventId: event.id, viewerRole: viewerRole.analyticsRole)
        }
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let fetchedEvent = eventRepo.event(event.id)
            async let allRSVPs = rsvpRepo.rsvps(for: event.id)
            async let mine = rsvpRepo.myRSVP(for: event.id, userId: userId)
            event = try await fetchedEvent
            rsvps = try await allRSVPs
            myRSVP = try await mine
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar el evento")
        }
    }

    // MARK: - RSVP

    public func setRSVP(_ status: RSVPStatus, plusOnes: Int = 0, reason: String? = nil) async {
        guard !isMutating else { return }
        let previous = myRSVP
        // Optimistic update — replace local immediately. Server may downgrade
        // .going → .waitlisted if at capacity; the post-RPC update lands the
        // truth when the server response comes back.
        myRSVP = RSVP(
            id: previous?.id ?? UUID(),
            eventId: event.id,
            userId: userId,
            status: status,
            respondedAt: .now,
            cancelledReason: reason,
            plusOnes: plusOnes
        )
        isMutating = true
        defer { isMutating = false }

        do {
            let updated = try await rsvpRepo.setRSVP(
                eventId: event.id, status: status, plusOnes: plusOnes, reason: reason
            )
            myRSVP = updated
            updateLocalRSVPList(with: updated)

            let hours = max(0, Int(event.startsAt.timeIntervalSince(.now) / 3600))
            await analytics.rsvpChanged(
                eventId: event.id,
                from: previous?.status ?? .pending,
                to: status,
                hoursToEvent: hours
            )

            // Sprint 1b: feed the rule engine. Two cases matter for V1 rules:
            //   1. Any RSVP submission → eventually used by future rules.
            //   2. Same-day flip → triggers the "Cancelación mismo día" rule.
            // The cron edge function process-system-events handles the rest.
            if let systemEvents {
                // user_id must be in the payload: the cron runs as service
                // role with no auth.uid(), and the rule engine's
                // rsvpChangedSameDay evaluator falls back to
                // payload.user_id to resolve the target member.
                let userIdString = userId.uuidString.lowercased()
                await systemEvents.emit(
                    .rsvpSubmitted,
                    groupId: group.id,
                    resourceId: event.id,
                    memberId: nil,
                    payload: .object([
                        "user_id": .string(userIdString),
                        "from":    .string(previous?.status.rawValue ?? "pending"),
                        "to":      .string(status.rawValue),
                        "plus_ones": .int(plusOnes)
                    ])
                )
                if isSameDayAsEvent && (previous?.status == .going) && status != .going {
                    await systemEvents.emit(
                        .rsvpChangedSameDay,
                        groupId: group.id,
                        resourceId: event.id,
                        memberId: nil,
                        payload: .object([
                            "user_id": .string(userIdString),
                            "from": .string(previous?.status.rawValue ?? "pending"),
                            "to":   .string(status.rawValue)
                        ])
                    )
                }
            }

            // Schedule / cancel local reminders.
            if let notifications {
                if status == .going {
                    let granted = notifications.authorizationStatus == .granted
                        ? true
                        : await notifications.requestAuthorization()
                    if granted {
                        await notifications.scheduleLocalReminders(for: event, vocabulary: group.eventVocabulary)
                    }
                } else {
                    await notifications.cancelLocalReminders(for: event.id)
                }
            }
        } catch {
            // Rollback.
            myRSVP = previous
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar tu RSVP")
        }
    }

    // MARK: - Check-in

    public func selfCheckIn(locationVerified: Bool = false) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await checkInRepo.selfCheckIn(
                eventId: event.id, userId: userId, locationVerified: locationVerified
            )
            myRSVP = updated
            updateLocalRSVPList(with: updated)
            await analytics.checkIn(eventId: event.id, method: .selfMethod, locationVerified: locationVerified)
            await emitCheckIn(arrivedAt: updated.arrivedAt)
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos marcar tu asistencia")
        }
    }

    public func hostMarkCheckIn(memberId: UUID) async {
        guard viewerRole == .host, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await checkInRepo.hostMarkCheckIn(eventId: event.id, memberId: memberId)
            updateLocalRSVPList(with: updated)
            await analytics.checkIn(eventId: event.id, method: .hostMarked, locationVerified: false)
            await emitCheckIn(arrivedAt: updated.arrivedAt, forMemberId: memberId)
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos marcar la asistencia")
        }
    }

    /// Sprint 1b: emit the `checkInRecorded` SystemEvent so the rule engine
    /// can fire the "Llegada tardía" escalating-fine rule. The minutes-late
    /// computation happens server-side using `events.starts_at`; we only
    /// pass the arrival timestamp + member context.
    private func emitCheckIn(arrivedAt: Date?, forMemberId: UUID? = nil) async {
        guard let systemEvents else { return }
        await systemEvents.emit(
            .checkInRecorded,
            groupId: group.id,
            resourceId: event.id,
            memberId: forMemberId,  // nil = self check-in; server resolves from auth.uid
            payload: .object([
                "arrived_at": .string(ISO8601DateFormatter().string(from: arrivedAt ?? .now))
            ])
        )
    }

    // MARK: - Host actions

    public func cancelEvent(reason: String?) async {
        guard viewerRole == .host || event.createdBy == userId else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            event = try await eventRepo.cancelEvent(event.id, reason: reason)
            await analytics.eventCancelled(eventId: event.id, by: .host, hasReason: reason != nil)
            // Cancel local reminders for the cancelled event.
            if let notifications {
                await notifications.cancelLocalReminders(for: event.id)
            }
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cancelar el evento")
        }
    }

    public func closeEvent(autoGenerateEnabled: Bool) async {
        guard viewerRole == .host else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            event = try await lifecycle.closeEvent(event, in: group, autoGenerateEnabled: autoGenerateEnabled)
            // Feed the rule engine. The platform's process-system-events
            // cron picks this up on the next minute via the eventClosed
            // SystemEvent emitted below.
            if let systemEvents {
                await systemEvents.emit(
                    .eventClosed,
                    groupId: group.id,
                    resourceId: event.id,
                    memberId: nil,
                    payload: .object([
                        "auto_generate": .bool(autoGenerateEnabled)
                    ])
                )
            }
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cerrar el evento")
        }
    }

    public func reopenEvent() async {
        // Server enforces permission (host or manageEvents) via mig 00295.
        // Client-side gate kept loose so a member with manageEvents but
        // not host can still trigger; the server will reject if neither.
        guard event.status == .closed || event.status == .cancelled else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            event = try await lifecycle.reopenEvent(event, in: group)
            // eventReopened SystemEvent is emitted server-side by the RPC
            // (mig 00295). No client emit needed here.
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos reabrir el evento")
        }
    }

    public func sendHostReminders() async -> Int {
        guard viewerRole == .host else { return 0 }
        let pendingCount = rsvps.filter { $0.status == .pending }.count

        // Real path: invoke send-event-notification(kind=host_reminder).
        // The edge fn resolves recipients server-side (pending RSVPs from
        // attendance_view), writes one outbox row per recipient. APNs
        // delivery is the dispatch-notifications cron's job.
        //
        // Rate-limit lives in the dispatcher actor (1 send / 30 min /
        // event). When the limit hits, we surface a friendly notice via
        // the error envelope — the existing toast/alert pathway already
        // handles `error` presentation.
        let count: Int
        if let dispatcher = notificationDispatcher {
            do {
                count = try await dispatcher.sendHostReminder(eventId: event.id)
            } catch let EventNotificationDispatchError.rateLimited(nextAt) {
                self.error = CoordinatorError(
                    title: "Ya recordaste hace poco",
                    message: "Espera \(formattedRateLimitWait(until: nextAt)) para volver a notificar a quienes faltan.",
                    isRetryable: false
                )
                return 0
            } catch {
                self.error = CoordinatorError.from(error, fallback: "No pudimos enviar el recordatorio")
                return 0
            }
        } else {
            // No dispatcher injected (preview / unit tests). Synthesize
            // the count from the local pending list so the analytics
            // call still records something meaningful.
            count = pendingCount
        }

        await analytics.hostReminderSent(eventId: event.id, recipientCount: count)
        return count
    }

    private func formattedRateLimitWait(until date: Date) -> String {
        let secs = Int(max(0, date.timeIntervalSinceNow))
        let mins = (secs + 59) / 60
        if mins <= 1 { return "1 minuto" }
        return "\(mins) minutos"
    }

    public func toggleAutoGenerate(_ enabled: Bool) async {
        do {
            try await lifecycle.setAutoGenerate(enabled, group: group)
            await analytics.autoGenerationToggled(enabled: enabled)
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos actualizar el ajuste")
        }
    }

    /// Host promotes the next waitlisted member to .going. Server enforces
    /// capacity check + admin/host gating.
    public func promoteFromWaitlist() async {
        guard viewerRole == .host, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let promoted = try await rsvpRepo.promoteFromWaitlist(eventId: event.id)
            updateLocalRSVPList(with: promoted)
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos promover de la lista de espera")
        }
    }

    /// Realtime subscription to event_attendance for this event. Called when
    /// the detail view appears. Updates `rsvps` + `myRSVP` whenever any
    /// attendee row changes — RSVP changes by other members reflect
    /// immediately without a manual refresh.
    private var realtimeTask: Task<Void, Never>?
    private var realtimeService: RSVPRealtimeService?

    public func startRealtime() async {
        guard realtimeTask == nil, let factory = realtimeFactory else { return }
        let service = factory(event.id)
        realtimeService = service
        realtimeTask = Task { [weak self] in
            for await change in service.changes {
                guard let self else { return }
                await self.applyRealtimeChange(change)
            }
        }
        await service.subscribe()
    }

    public func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        Task { [realtimeService] in await realtimeService?.unsubscribe() }
        realtimeService = nil
    }

    private func applyRealtimeChange(_ change: RSVPRealtimeService.Change) async {
        switch change {
        case .kick:
            // Post-mig 00164 (Constitution audit Gap 6): the realtime
            // service no longer decodes payload rows because the canonical
            // RSVP shape (attendance_view) merges two atoms — there's no
            // single row to upsert. Refetch the merged projection.
            await refresh()
        }
    }

    public func generateWalletPass() async -> URL? {
        guard walletService.isAvailable else { return nil }
        // For V1 we don't have Member resolved here; the sheet view passes it.
        // Returning nil here keeps the contract clean.
        return nil
    }

    public func clearError() { error = nil }

    // MARK: - Helpers

    private func updateLocalRSVPList(with updated: RSVP) {
        if let idx = rsvps.firstIndex(where: { $0.userId == updated.userId }) {
            rsvps[idx] = updated
        } else {
            rsvps.append(updated)
        }
    }

    /// True when "now" is the same calendar day as the event's start in the
    /// device's local timezone. Used to gate `rsvpChangedSameDay` SystemEvent
    /// emission so we don't fire it for legitimate next-week changes.
    private var isSameDayAsEvent: Bool {
        Calendar.current.isDate(.now, inSameDayAs: event.startsAt)
    }
}

public extension EventDetailCoordinator.ViewerRole {
    var analyticsRole: EventAnalytics.ViewerRole {
        switch self {
        case .host:       return .host
        case .guestRole:  return .guestRole
        }
    }
}

// MARK: - EventInteractor conformance

extension EventDetailCoordinator: EventInteractor {
    /// Convenience for `EventInteractor.viewerIsHost`. Avoids leaking the
    /// `ViewerRole` enum into sections that only care about the boolean.
    public var viewerIsHost: Bool { viewerRole == .host }

    /// Convenience for `EventInteractor.walletAvailable`. Mirrors the
    /// underlying `WalletPassService.isAvailable` flag.
    public var walletAvailable: Bool { walletService.isAvailable }

    /// Default-argument bridge to the existing async method. Required so
    /// the protocol witness picks up the call without callers having to
    /// supply `plusOnes:` / `reason:` every time.
    public func setRSVP(_ status: RSVPStatus) async {
        await setRSVP(status, plusOnes: 0, reason: nil)
    }
}
