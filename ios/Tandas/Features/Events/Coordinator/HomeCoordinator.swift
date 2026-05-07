import Foundation
import Observation
import OSLog

@Observable @MainActor
final class HomeCoordinator {
    private(set) var nextEvent: Event?
    private(set) var upcomingEvents: [Event] = []

    /// Resource-shaped accessor sobre `nextEvent`. V1 deriva trivialmente
    /// envolviendo en `EventResource`; cuando un segundo resource type
    /// shippee, este passa a ser canonical y `nextEvent` se elimina (Path B
    /// additive de Sub-fase B — Phase 0.5 audit § 5.1 #8).
    var nextResource: (any ResourceProtocol)? {
        nextEvent.map(EventResource.init)
    }

    private(set) var myRSVPs: [UUID: RSVP] = [:]
    private(set) var isLoading: Bool = false
    private(set) var error: CoordinatorError?
    private(set) var lastRefreshedAt: Date?

    /// "Active" group — preserved for back-compat (header label, group-scoped
    /// callbacks, deeplink targets). In multi-group mode the upcoming feed
    /// queries across `allGroups`, so this is no longer the filter scope.
    let group: Group
    /// All groups the user belongs to. Cross-grupos mode kicks in when count
    /// > 1 (DS v3 §4.1-4.6/4.9). Drives `group(for:)` lookup so each row can
    /// surface a `RuulOriginTag` with the originating group's identity.
    private(set) var allGroups: [Group]
    private let userId: UUID
    private let eventRepo: any EventRepository
    private let rsvpRepo: any RSVPRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "home")

    private let cacheTTL: TimeInterval = 5 * 60

    /// True when the user belongs to >1 group. HomeView uses this to decide
    /// whether to render `RuulOriginTag` on rows + hero (per DS §4.6 — no tag
    /// in single-group mode, redundant).
    var isCrossGroupsMode: Bool { allGroups.count > 1 }

    init(
        group: Group,
        allGroups: [Group],
        userId: UUID,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository
    ) {
        self.group = group
        self.allGroups = allGroups.isEmpty ? [group] : allGroups
        self.userId = userId
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
    }

    /// Convenience init — single-group mode (back-compat for tests/previews).
    /// Equivalent to passing `allGroups: [group]`, which forces single-group
    /// path in `refresh()`.
    convenience init(
        group: Group,
        userId: UUID,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository
    ) {
        self.init(
            group: group,
            allGroups: [group],
            userId: userId,
            eventRepo: eventRepo,
            rsvpRepo: rsvpRepo
        )
    }

    /// Returns the originating group for an event, or nil if the event's
    /// groupId isn't in `allGroups` (shouldn't happen in practice but safe).
    func group(for event: Event) -> Group? {
        allGroups.first { $0.id == event.groupId }
    }

    func refresh(force: Bool = false) async {
        if !force, let last = lastRefreshedAt, Date.now.timeIntervalSince(last) < cacheTTL {
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let upcoming: [Event]
            if isCrossGroupsMode {
                upcoming = try await eventRepo.upcomingEventsAcrossGroups(
                    groupIds: allGroups.map(\.id),
                    limit: 20
                )
            } else {
                upcoming = try await eventRepo.upcomingEvents(in: group.id, limit: 20)
            }
            upcomingEvents = upcoming
            nextEvent = upcoming.first
            // Fetch myRSVP for the next event only (cheap). Detail view does
            // its own fetch for the full RSVP list.
            if let next = nextEvent {
                let rsvp = try await rsvpRepo.myRSVP(for: next.id, userId: userId)
                if let rsvp { myRSVPs[next.id] = rsvp }
            }
            lastRefreshedAt = .now
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tus eventos")
            log.warning("home refresh failed: \(error.localizedDescription)")
        }
    }

    func clearError() { error = nil }
}
