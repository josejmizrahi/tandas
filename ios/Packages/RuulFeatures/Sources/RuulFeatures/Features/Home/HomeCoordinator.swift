import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class HomeCoordinator {
    public private(set) var nextEvent: Event?
    public private(set) var upcomingEvents: [Event] = []
    public private(set) var upcomingResources: [ResourceRow] = []

    /// Resource-shaped accessor sobre `nextEvent`. V1: el único concrete
    /// resource es Event. Ya no se envuelve en un wrapper — Event conforma
    /// a Resource directamente (Plan 1, Task 9). Cuando llegue Slot/Fund
    /// en Phase 2, este accessor extiende para retornar un resource del
    /// primer módulo activo cuyo type esté disponible.
    public var nextResource: (any Resource)? {
        nextEvent
    }

    public private(set) var myRSVPs: [UUID: RSVP] = [:]
    public private(set) var isLoading: Bool = false
    public private(set) var error: CoordinatorError?
    public private(set) var lastRefreshedAt: Date?

    /// "Active" group — preserved for back-compat (header label, group-scoped
    /// callbacks, deeplink targets). In multi-group mode the upcoming feed
    /// queries across `allGroups`, so this is no longer the filter scope.
    public let group: Group
    /// All groups the user belongs to. Cross-grupos mode kicks in when count
    /// > 1 (DS v3 §4.1-4.6/4.9). Drives `group(for:)` lookup so each row can
    /// surface a `RuulOriginTag` with the originating group's identity.
    public private(set) var allGroups: [Group]
    private let userId: UUID
    private let eventRepo: any EventRepository
    private let rsvpRepo: any RSVPRepository
    private let resourceRepo: any ResourceRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "home")

    private let cacheTTL: TimeInterval = 5 * 60

    /// True when the user belongs to >1 group. HomeView uses this to decide
    /// whether to render `RuulOriginTag` on rows + hero (per DS §4.6 — no tag
    /// in single-group mode, redundant).
    public var isCrossGroupsMode: Bool { allGroups.count > 1 }

    public init(
        group: Group,
        allGroups: [Group],
        userId: UUID,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository,
        resourceRepo: any ResourceRepository
    ) {
        self.group = group
        self.allGroups = allGroups.isEmpty ? [group] : allGroups
        self.userId = userId
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
        self.resourceRepo = resourceRepo
    }

    /// Convenience init — single-group mode (back-compat for tests/previews).
    /// Equivalent to passing `allGroups: [group]`, which forces single-group
    /// path in `refresh()`.
    public convenience init(
        group: Group,
        userId: UUID,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository,
        resourceRepo: any ResourceRepository
    ) {
        self.init(
            group: group,
            allGroups: [group],
            userId: userId,
            eventRepo: eventRepo,
            rsvpRepo: rsvpRepo,
            resourceRepo: resourceRepo
        )
    }

    /// Returns the originating group for an event, or nil if the event's
    /// groupId isn't in `allGroups` (shouldn't happen in practice but safe).
    public func group(for event: Event) -> Group? {
        allGroups.first { $0.id == event.groupId }
    }

    public func refresh(force: Bool = false) async {
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
        // Fetch non-event resources (fund/asset/slot/space) independently so an
        // error here never blocks the event feed. Sequential per-group to keep
        // logic simple; batch optimisation deferred.
        let groupIds = isCrossGroupsMode ? allGroups.map(\.id) : [group.id]
        var allRows: [ResourceRow] = []
        for gid in groupIds {
            let rows = (try? await resourceRepo.list(
                in: gid,
                types: [.fund, .asset, .slot, .space],
                statuses: nil,
                limit: 20
            )) ?? []
            allRows.append(contentsOf: rows)
        }
        upcomingResources = allRows
    }

    public func clearError() { error = nil }
}
