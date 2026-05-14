import Testing
import Foundation
import RuulCore
import RuulFeatures
@testable import Tandas

/// Beta 1 W1 D-1.1 — regression coverage for the host-reminder wire.
///
/// Bug: `EventDetailCoordinator.sendHostReminders` only emitted analytics
/// without invoking the `send-event-notification` edge function. Hosts
/// thought they had nudged pending guests; nothing was queued.
///
/// Fix: dispatcher pluggable via init; `Live` impl wraps
/// `client.functions.invoke("send-event-notification", kind: host_reminder)`.
/// Per-event 30-min client-side rate limit lives in the dispatcher actor
/// so multiple coordinator instances can't combine to spam.
@Suite("EventDetailCoordinator host reminder dispatch")
@MainActor
struct SendHostRemindersTests {

    private func sampleGroup() -> RuulCore.Group {
        RuulCore.Group(
            id: UUID(),
            name: "G",
            inviteCode: "x",
            activeModules: ["rsvp"],
            createdBy: UUID(),
            createdAt: .now
        )
    }

    private func sampleEvent(host: UUID, group: RuulCore.Group) -> Event {
        Event(
            id: UUID(),
            groupId: group.id,
            title: "Cena",
            startsAt: .now.addingTimeInterval(3600),
            hostId: host,
            createdBy: host,
            createdAt: .now
        )
    }

    private func makeCoord(
        viewerIsHost: Bool,
        dispatcher: (any EventNotificationDispatcher)?
    ) -> EventDetailCoordinator {
        let group = sampleGroup()
        let userId = UUID()
        let event = sampleEvent(host: viewerIsHost ? userId : UUID(), group: group)
        let eventRepo = MockEventRepository(seed: [event])
        let rsvpRepo = MockRSVPRepository()
        let checkRepo = MockCheckInRepository()
        let lifecycle = EventLifecycleService(eventRepo: eventRepo)
        let analytics = EventAnalytics(analytics: MockAnalyticsService())

        return EventDetailCoordinator(
            event: event,
            group: group,
            userId: userId,
            eventRepo: eventRepo,
            rsvpRepo: rsvpRepo,
            checkInRepo: checkRepo,
            lifecycle: lifecycle,
            notifications: nil,
            walletService: StubWalletPassService(),
            analytics: analytics,
            notificationDispatcher: dispatcher
        )
    }

    @Test("Host with mock dispatcher returns dispatcher's outbox count")
    func dispatcherIsInvoked() async throws {
        let dispatcher = MockEventNotificationDispatcher(stubResponseCount: 4)
        let coord = makeCoord(viewerIsHost: true, dispatcher: dispatcher)

        let returned = await coord.sendHostReminders()

        #expect(returned == 4)
        let sent = await dispatcher.sent
        #expect(sent.count == 1)
        #expect(sent.first == coord.event.id)
        #expect(coord.error == nil)
    }

    @Test("Non-host returns 0 and never invokes dispatcher")
    func nonHostShortCircuits() async {
        let dispatcher = MockEventNotificationDispatcher(stubResponseCount: 99)
        let coord = makeCoord(viewerIsHost: false, dispatcher: dispatcher)

        let returned = await coord.sendHostReminders()

        #expect(returned == 0)
        let sent = await dispatcher.sent
        #expect(sent.isEmpty)
    }

    @Test("Without dispatcher (preview/legacy) falls back to local pending count")
    func nilDispatcherFallback() async {
        // No dispatcher injected — coordinator synthesizes count from
        // its in-memory rsvp list. Empty list → 0. We just want the
        // call to succeed (no crash, no error envelope set).
        let coord = makeCoord(viewerIsHost: true, dispatcher: nil)
        let returned = await coord.sendHostReminders()
        #expect(returned == 0)
        #expect(coord.error == nil)
    }

    @Test("Rate-limited error surfaces a friendly title via error envelope")
    func rateLimitedSurfacesError() async {
        let dispatcher = RateLimitedFakeDispatcher(
            nextAvailableAt: .now.addingTimeInterval(15 * 60)
        )
        let coord = makeCoord(viewerIsHost: true, dispatcher: dispatcher)

        let returned = await coord.sendHostReminders()

        #expect(returned == 0)
        #expect(coord.error?.title == "Ya recordaste hace poco")
        // Message should mention minutes remaining (15 ± 1 due to rounding).
        let msg = coord.error?.message ?? ""
        #expect(msg.contains("minuto"))
    }

    @Test("Edge failure surfaces a generic 'No pudimos enviar' fallback")
    func edgeFailureSurfacesError() async {
        let dispatcher = ThrowingFakeDispatcher(
            error: EventNotificationDispatchError.edgeFailure("network down")
        )
        let coord = makeCoord(viewerIsHost: true, dispatcher: dispatcher)

        let returned = await coord.sendHostReminders()

        #expect(returned == 0)
        #expect(coord.error?.title == "No pudimos enviar el recordatorio")
    }
}

// MARK: - Fixtures

/// Throws `.rateLimited` on every call.
private actor RateLimitedFakeDispatcher: EventNotificationDispatcher {
    let nextAvailableAt: Date
    init(nextAvailableAt: Date) { self.nextAvailableAt = nextAvailableAt }
    func sendHostReminder(eventId: UUID) async throws -> Int {
        throw EventNotificationDispatchError.rateLimited(nextAvailableAt: nextAvailableAt)
    }
}

/// Throws an arbitrary `EventNotificationDispatchError`.
private actor ThrowingFakeDispatcher: EventNotificationDispatcher {
    let error: Error
    init(error: Error) { self.error = error }
    func sendHostReminder(eventId: UUID) async throws -> Int {
        throw error
    }
}
