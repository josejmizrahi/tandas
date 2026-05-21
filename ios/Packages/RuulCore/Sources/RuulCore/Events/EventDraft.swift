import Foundation

/// In-memory mutable draft used by the event create + edit flows
/// (`ResourceWizardCoordinator` + `EventResourceBuilder` for create;
/// `ResourceEditCoordinator` for edit). Not persisted — single-shot per
/// session, no SwiftData restore.
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
    /// Max seats (going + plus-ones). `nil` = unlimited. Surfaced in the
    /// edit form so hosts can cap attendance after-the-fact.
    public var capacityMax: Int?
    /// When true, attendees can declare `plusOnes > 0` on their RSVP.
    public var allowPlusOnes: Bool = false
    /// Cap per attendee. 0 = each attendee may bring nobody. Ignored when
    /// `allowPlusOnes` is false.
    public var maxPlusOnesPerMember: Int = 0
    /// Optional cutoff for accepting RSVPs. `nil` = no cutoff. UI surfaces
    /// it under the "Confirmaciones" section.
    public var rsvpDeadline: Date?

    public init(
        title: String = "",
        coverImageName: String? = nil,
        coverImageURL: URL? = nil,
        description: String = "",
        startsAt: Date,
        durationMinutes: Int = 180,
        locationName: String? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil,
        hostId: UUID? = nil,
        applyRules: Bool = true,
        capacityMax: Int? = nil,
        allowPlusOnes: Bool = false,
        maxPlusOnesPerMember: Int = 0,
        rsvpDeadline: Date? = nil
    ) {
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
        self.capacityMax = capacityMax
        self.allowPlusOnes = allowPlusOnes
        self.maxPlusOnesPerMember = maxPlusOnesPerMember
        self.rsvpDeadline = rsvpDeadline
    }

    public var isReadyToPublish: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func empty(suggestedDate: Date) -> EventDraft {
        EventDraft(startsAt: suggestedDate)
    }
}
