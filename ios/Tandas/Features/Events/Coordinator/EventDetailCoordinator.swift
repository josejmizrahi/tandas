import Foundation
import Observation
import OSLog

@Observable @MainActor
final class EventDetailCoordinator {
    enum ViewerRole: Sendable, Hashable { case host, guestRole }

    private(set) var event: Event
    private(set) var rsvps: [RSVP] = []
    private(set) var myRSVP: RSVP?
    private(set) var isLoading: Bool = false
    private(set) var isMutating: Bool = false
    private(set) var error: EventError?

    let viewerRole: ViewerRole
    let group: Group
    private let userId: UUID
    private let eventRepo: any EventRepository
    private let rsvpRepo: any RSVPRepository
    private let checkInRepo: any CheckInRepository
    private let lifecycle: EventLifecycleService
    private let notifications: NotificationService?
    let walletService: any WalletPassService
    private let analytics: EventAnalytics
    private let realtimeFactory: ((UUID) -> RSVPRealtimeService)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.detail")

    init(
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
        realtimeFactory: ((UUID) -> RSVPRealtimeService)? = nil
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
        self.walletService = walletService
        self.analytics = analytics
        self.realtimeFactory = realtimeFactory
        Task {
            await analytics.eventView(eventId: event.id, viewerRole: viewerRole.analyticsRole)
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedEvent = eventRepo.event(event.id)
            async let allRSVPs = rsvpRepo.rsvps(for: event.id)
            async let mine = rsvpRepo.myRSVP(for: event.id, userId: userId)
            event = try await fetchedEvent
            rsvps = try await allRSVPs
            myRSVP = try await mine
        } catch {
            self.error = .fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - RSVP

    func setRSVP(_ status: RSVPStatus, plusOnes: Int = 0, reason: String? = nil) async {
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
            self.error = .rsvpFailed(error.localizedDescription)
        }
    }

    // MARK: - Check-in

    func selfCheckIn(locationVerified: Bool = false) async {
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
        } catch {
            self.error = .checkInFailed(error.localizedDescription)
        }
    }

    func hostMarkCheckIn(memberId: UUID) async {
        guard viewerRole == .host, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await checkInRepo.hostMarkCheckIn(eventId: event.id, memberId: memberId)
            updateLocalRSVPList(with: updated)
            await analytics.checkIn(eventId: event.id, method: .hostMarked, locationVerified: false)
        } catch {
            self.error = .checkInFailed(error.localizedDescription)
        }
    }

    // MARK: - Host actions

    func cancelEvent(reason: String?) async {
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
            self.error = .cancelFailed(error.localizedDescription)
        }
    }

    func closeEvent(autoGenerateEnabled: Bool) async {
        guard viewerRole == .host else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            event = try await lifecycle.closeEvent(event, in: group, autoGenerateEnabled: autoGenerateEnabled)
        } catch {
            self.error = .closeFailed(error.localizedDescription)
        }
    }

    func sendHostReminders() async -> Int {
        guard viewerRole == .host else { return 0 }
        let pendingCount = rsvps.filter { $0.status == .pending }.count
        // Real send happens via send-event-notification edge function (stub V1).
        await analytics.hostReminderSent(eventId: event.id, recipientCount: pendingCount)
        return pendingCount
    }

    func toggleAutoGenerate(_ enabled: Bool) async {
        do {
            try await lifecycle.setAutoGenerate(enabled, group: group)
            await analytics.autoGenerationToggled(enabled: enabled)
        } catch {
            self.error = .updateFailed(error.localizedDescription)
        }
    }

    /// Host promotes the next waitlisted member to .going. Server enforces
    /// capacity check + admin/host gating.
    func promoteFromWaitlist() async {
        guard viewerRole == .host, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let promoted = try await rsvpRepo.promoteFromWaitlist(eventId: event.id)
            updateLocalRSVPList(with: promoted)
        } catch {
            self.error = .rsvpFailed(error.localizedDescription)
        }
    }

    /// Realtime subscription to event_attendance for this event. Called when
    /// the detail view appears. Updates `rsvps` + `myRSVP` whenever any
    /// attendee row changes — RSVP changes by other members reflect
    /// immediately without a manual refresh.
    private var realtimeTask: Task<Void, Never>?
    private var realtimeService: RSVPRealtimeService?

    func startRealtime() async {
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

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        Task { [realtimeService] in await realtimeService?.unsubscribe() }
        realtimeService = nil
    }

    private func applyRealtimeChange(_ change: RSVPRealtimeService.Change) async {
        switch change {
        case .upsert(let rsvp):
            updateLocalRSVPList(with: rsvp)
            if rsvp.userId == userId { myRSVP = rsvp }
        case .delete(let rsvpId):
            rsvps.removeAll { $0.id == rsvpId }
        }
    }

    func generateWalletPass() async -> URL? {
        guard walletService.isAvailable else { return nil }
        // For V1 we don't have Member resolved here; the sheet view passes it.
        // Returning nil here keeps the contract clean.
        return nil
    }

    func clearError() { error = nil }

    // MARK: - Helpers

    private func updateLocalRSVPList(with updated: RSVP) {
        if let idx = rsvps.firstIndex(where: { $0.userId == updated.userId }) {
            rsvps[idx] = updated
        } else {
            rsvps.append(updated)
        }
    }
}

extension EventDetailCoordinator.ViewerRole {
    var analyticsRole: EventAnalytics.ViewerRole {
        switch self {
        case .host:       return .host
        case .guestRole:  return .guestRole
        }
    }
}
