import Foundation
import Observation
import OSLog

/// Cross-group event feed. Loads events from every group the caller
/// belongs to (RLS scopes the query) and groups them by temporal section
/// for `MyFeedView`.
@Observable
@MainActor
final class MyFeedCoordinator {
    private let eventRepo: any EventRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "feed")

    var events: [Event] = []
    var groupsById: [UUID: Group] = [:]
    var isLoading: Bool = false
    var loadError: String?

    init(eventRepo: any EventRepository, groupsRepo: any GroupsRepository) {
        self.eventRepo = eventRepo
        self.groupsRepo = groupsRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        do {
            async let evts = eventRepo.feedAcrossGroups(limit: 100)
            async let grps = groupsRepo.listMine()
            let (loadedEvents, loadedGroups) = try await (evts, grps)
            self.events = loadedEvents
            self.groupsById = Dictionary(uniqueKeysWithValues: loadedGroups.map { ($0.id, $0) })
        } catch {
            log.error("feed refresh failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // MARK: - Sectioning

    enum Section: Hashable, CaseIterable {
        case today
        case thisWeek
        case upcoming
        case recent

        var title: String {
            switch self {
            case .today:    return "Hoy"
            case .thisWeek: return "Esta semana"
            case .upcoming: return "Próximos"
            case .recent:   return "Recientes"
            }
        }
    }

    func sectioned() -> [(Section, [Event])] {
        let calendar = Calendar.current
        let now = Date.now
        let endOfToday = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: now) ?? now

        var today: [Event] = []
        var thisWeek: [Event] = []
        var upcoming: [Event] = []
        var recent: [Event] = []

        for ev in events {
            if ev.startsAt < now {
                if ev.startsAt >= now.addingTimeInterval(-14 * 86_400) {
                    recent.append(ev)
                }
            } else if ev.startsAt <= endOfToday {
                today.append(ev)
            } else if ev.startsAt <= endOfWeek {
                thisWeek.append(ev)
            } else {
                upcoming.append(ev)
            }
        }

        recent.sort { $0.startsAt > $1.startsAt }

        var result: [(Section, [Event])] = []
        if !today.isEmpty    { result.append((.today, today)) }
        if !thisWeek.isEmpty { result.append((.thisWeek, thisWeek)) }
        if !upcoming.isEmpty { result.append((.upcoming, upcoming)) }
        if !recent.isEmpty   { result.append((.recent, recent)) }
        return result
    }

    func group(for event: Event) -> Group? {
        groupsById[event.groupId]
    }
}
