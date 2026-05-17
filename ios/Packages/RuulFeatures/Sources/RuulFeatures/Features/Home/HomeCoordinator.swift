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

    /// Active group whose feed is currently displayed. Mutable so the
    /// coordinator can outlive a group switch (see `setActiveGroup`) and
    /// avoid the empty→loading→loaded flash you'd get from rebuilding a
    /// fresh instance every time the user picks a different group.
    public private(set) var group: Group
    /// All groups the user belongs to. Cross-grupos mode kicks in when count
    /// > 1 (DS v3 §4.1-4.6/4.9). Drives `group(for:)` lookup so each row can
    /// surface a `RuulOriginTag` with the originating group's identity.
    public private(set) var allGroups: [Group]
    public let userId: UUID
    private let eventRepo: any EventRepository
    private let rsvpRepo: any RSVPRepository
    private let resourceRepo: any ResourceRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "home")

    private let cacheTTL: TimeInterval = 5 * 60

    /// Snapshot of a single group's feed, kept around so `setActiveGroup`
    /// can rehydrate the visible state instantly when the user toggles back
    /// to a group they've already seen this session.
    private struct GroupSnapshot {
        var nextEvent: Event?
        var upcomingEvents: [Event]
        var upcomingResources: [ResourceRow]
        var myRSVPs: [UUID: RSVP]
        var lastRefreshedAt: Date?
    }

    /// Per-group cache of the last visible state. Populated whenever
    /// `setActiveGroup` is called or `refresh()` completes. Bounded by the
    /// number of groups the user belongs to, so no LRU eviction is needed
    /// for realistic memberships.
    private var perGroupCache: [UUID: GroupSnapshot] = [:]

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

    /// Swaps the visible group without rebuilding the coordinator. Caches
    /// the outgoing group's feed, restores the incoming group's cached
    /// feed (if any), then kicks a background refresh so any new data
    /// from since the last visit lands without blocking the swap.
    ///
    /// This is what gives the group switcher its instant feel — without
    /// it, RootShell rebuilds a fresh coordinator on every switch and
    /// HomeView flashes through `RuulLoadingState` while the new fetch
    /// runs.
    public func setActiveGroup(_ newGroup: Group, allGroups: [Group]? = nil) {
        // No-op when the user re-picks the active group (idempotent).
        guard newGroup.id != group.id else {
            if let allGroups { self.allGroups = allGroups.isEmpty ? [newGroup] : allGroups }
            return
        }

        // Snapshot the outgoing group so a swap back is instant.
        perGroupCache[group.id] = GroupSnapshot(
            nextEvent: nextEvent,
            upcomingEvents: upcomingEvents,
            upcomingResources: upcomingResources,
            myRSVPs: myRSVPs,
            lastRefreshedAt: lastRefreshedAt
        )

        group = newGroup
        if let allGroups { self.allGroups = allGroups.isEmpty ? [newGroup] : allGroups }

        if let snap = perGroupCache[newGroup.id] {
            // Hot path: rehydrate from cache. The TTL check inside
            // refresh() decides whether the background fetch fires.
            nextEvent = snap.nextEvent
            upcomingEvents = snap.upcomingEvents
            upcomingResources = snap.upcomingResources
            myRSVPs = snap.myRSVPs
            lastRefreshedAt = snap.lastRefreshedAt
        } else {
            // Cold path: never visited this group → clear visible state
            // so the loading skeleton renders only the first time per
            // session. Subsequent visits hit the hot path above.
            nextEvent = nil
            upcomingEvents = []
            upcomingResources = []
            // myRSVPs intentionally not cleared — it's keyed by event id,
            // so stale entries from other groups don't collide and the
            // map just grows by at most one entry per group visited.
            lastRefreshedAt = nil
        }

        error = nil
        // Background refresh — the cache TTL in `refresh()` skips the
        // network call when the snapshot is still fresh.
        Task { await refresh() }
    }

    public func refresh(force: Bool = false) async {
        if !force, let last = lastRefreshedAt, Date.now.timeIntervalSince(last) < cacheTTL {
            return
        }
        // Snapshot the group id at the start. If the user picks a
        // different group while this refresh is in flight, the result is
        // for the wrong scope — we keep it in the cache for that group
        // but never overwrite the now-active group's visible state.
        let refreshingGroupId = group.id
        let refreshingCrossGroupMode = isCrossGroupsMode
        let refreshingAllGroupIds = allGroups.map(\.id)

        isLoading = true
        error = nil
        defer { isLoading = false }

        var fetchedEvents: [Event] = []
        var fetchedNextRSVP: RSVP?
        var fetchedNext: Event?
        var eventsFetchSucceeded = false
        do {
            let upcoming: [Event]
            if refreshingCrossGroupMode {
                upcoming = try await eventRepo.upcomingEventsAcrossGroups(
                    groupIds: refreshingAllGroupIds,
                    limit: 20
                )
            } else {
                upcoming = try await eventRepo.upcomingEvents(in: refreshingGroupId, limit: 20)
            }
            fetchedEvents = upcoming
            fetchedNext = upcoming.first
            if let next = fetchedNext {
                fetchedNextRSVP = try await rsvpRepo.myRSVP(for: next.id, userId: userId)
            }
            eventsFetchSucceeded = true
        } catch {
            // Only surface the error when the user is still on the group
            // whose refresh failed — otherwise it'd appear under a feed
            // that didn't actually fail.
            if refreshingGroupId == group.id {
                self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tus eventos")
            }
            log.warning("home refresh failed: \(error.localizedDescription)")
        }

        // Non-event resources fetched independently so an event-side
        // failure doesn't kill the resources list (and vice versa).
        let groupIds = refreshingCrossGroupMode ? refreshingAllGroupIds : [refreshingGroupId]
        var fetchedRows: [ResourceRow] = []
        for gid in groupIds {
            let rows = (try? await resourceRepo.list(
                in: gid,
                types: [.fund, .asset, .slot, .space],
                statuses: nil,
                limit: 20
            )) ?? []
            fetchedRows.append(contentsOf: rows)
        }

        // Skip the cache write when the events fetch failed — otherwise
        // the TTL guard at the top would short-circuit subsequent
        // refreshes and keep the user stuck with empty arrays.
        guard eventsFetchSucceeded else {
            // Still paint the (possibly empty) resources fetch when the
            // user is on this group, since that fetch did succeed.
            if refreshingGroupId == group.id {
                upcomingResources = fetchedRows
            }
            return
        }

        let now = Date.now
        let snapshotRSVPs: [UUID: RSVP] = {
            guard let nxt = fetchedNext, let rsvp = fetchedNextRSVP else { return myRSVPs }
            var copy = myRSVPs
            copy[nxt.id] = rsvp
            return copy
        }()

        perGroupCache[refreshingGroupId] = GroupSnapshot(
            nextEvent: fetchedNext,
            upcomingEvents: fetchedEvents,
            upcomingResources: fetchedRows,
            myRSVPs: snapshotRSVPs,
            lastRefreshedAt: now
        )

        // Only paint the visible state if the user is still on this group.
        guard refreshingGroupId == group.id else { return }
        upcomingEvents = fetchedEvents
        nextEvent = fetchedNext
        if let nxt = fetchedNext, let rsvp = fetchedNextRSVP {
            myRSVPs[nxt.id] = rsvp
        }
        upcomingResources = fetchedRows
        lastRefreshedAt = now
    }

    public func clearError() { error = nil }
}
