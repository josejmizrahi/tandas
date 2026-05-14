import Foundation

/// In-memory mutable draft used by `ResourceCreationCoordinator`. Not persisted
/// (event creation is single-shot from CreateEventView; no SwiftData restore).
public struct EventDraft: Sendable, Hashable {
    public var title: String = ""
    public var coverImageName: String?
    public var coverImageURL: URL?
    public var description: String = ""
    public var startsAt: Date
    public var durationMinutes: Int = 180
    public var locationName: String?
    public var locationLat: Double?
    public var locationLng: Double?
    public var hostId: UUID?
    public var applyRules: Bool = true
    public var recurrenceOption: RecurrenceOption = .onlyThis

    public init(title: String = "", coverImageName: String? = nil, coverImageURL: URL? = nil, description: String = "", startsAt: Date, durationMinutes: Int = 180, locationName: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil, hostId: UUID? = nil, applyRules: Bool = true, recurrenceOption: RecurrenceOption = .onlyThis) {
        self.title = title
        self.coverImageName = coverImageName
        self.coverImageURL = coverImageURL
        self.description = description
        self.startsAt = startsAt
        self.durationMinutes = durationMinutes
        self.locationName = locationName
        self.locationLat = locationLat
        self.locationLng = locationLng
        self.hostId = hostId
        self.applyRules = applyRules
        self.recurrenceOption = recurrenceOption
    }

    public var isReadyToPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func empty(suggestedDate: Date) -> EventDraft {
        EventDraft(startsAt: suggestedDate)
    }
}
