import Foundation
import Observation
import OSLog

@Observable @MainActor
final class HomeCoordinator {
    private(set) var nextEvent: Event?
    private(set) var upcomingEvents: [Event] = []
    private(set) var myRSVPs: [UUID: RSVP] = [:]
    private(set) var isLoading: Bool = false
    private(set) var error: EventError?
    private(set) var lastRefreshedAt: Date?

    let group: Group
    private let userId: UUID
    private let eventRepo: any EventRepository
    private let rsvpRepo: any RSVPRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "home")

    private let cacheTTL: TimeInterval = 5 * 60

    init(
        group: Group,
        userId: UUID,
        eventRepo: any EventRepository,
        rsvpRepo: any RSVPRepository
    ) {
        self.group = group
        self.userId = userId
        self.eventRepo = eventRepo
        self.rsvpRepo = rsvpRepo
    }

    func refresh(force: Bool = false) async {
        if !force, let last = lastRefreshedAt, Date.now.timeIntervalSince(last) < cacheTTL {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let upcoming = try await eventRepo.upcomingEvents(in: group.id, limit: 20)
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
            self.error = .fetchFailed(error.localizedDescription)
            log.warning("home refresh failed: \(error.localizedDescription)")
        }
    }

    func clearError() { error = nil }
}
