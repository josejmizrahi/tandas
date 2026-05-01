import Foundation

/// In-memory mutable draft used by `EventCreationCoordinator`. Not persisted
/// (event creation is single-shot from CreateEventView; no SwiftData restore).
struct EventDraft: Sendable, Hashable {
    var title: String = ""
    var coverImageName: String?
    var coverImageURL: URL?
    var description: String = ""
    var startsAt: Date
    var durationMinutes: Int = 180
    var locationName: String?
    var locationLat: Double?
    var locationLng: Double?
    var hostId: UUID?
    var applyRules: Bool = true
    var recurrenceOption: RecurrenceOption = .onlyThis

    var isReadyToPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func empty(suggestedDate: Date) -> EventDraft {
        EventDraft(startsAt: suggestedDate)
    }
}
