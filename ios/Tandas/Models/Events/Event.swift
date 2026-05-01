import Foundation

struct Event: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let title: String
    let coverImageName: String?
    let coverImageURL: URL?
    let description: String?
    let startsAt: Date
    let endsAt: Date?
    let durationMinutes: Int
    let locationName: String?
    let locationLat: Double?
    let locationLng: Double?
    let hostId: UUID?
    let applyRules: Bool
    let status: EventStatus
    let cancellationReason: String?
    let isRecurringGenerated: Bool
    let parentEventId: UUID?
    let cycleNumber: Int?
    let rsvpDeadline: Date?
    let closedAt: Date?
    let createdBy: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case groupId               = "group_id"
        case coverImageName        = "cover_image_name"
        case coverImageURL         = "cover_image_url"
        case startsAt              = "starts_at"
        case endsAt                = "ends_at"
        case durationMinutes       = "duration_minutes"
        case locationName          = "location"
        case locationLat           = "location_lat"
        case locationLng           = "location_lng"
        case hostId                = "host_id"
        case applyRules            = "apply_rules"
        case cancellationReason    = "cancellation_reason"
        case isRecurringGenerated  = "is_recurring_generated"
        case parentEventId         = "parent_event_id"
        case cycleNumber           = "cycle_number"
        case rsvpDeadline          = "rsvp_deadline"
        case closedAt              = "closed_at"
        case createdBy             = "created_by"
        case createdAt             = "created_at"
    }

    init(
        id: UUID,
        groupId: UUID,
        title: String,
        coverImageName: String? = nil,
        coverImageURL: URL? = nil,
        description: String? = nil,
        startsAt: Date,
        endsAt: Date? = nil,
        durationMinutes: Int = 180,
        locationName: String? = nil,
        locationLat: Double? = nil,
        locationLng: Double? = nil,
        hostId: UUID? = nil,
        applyRules: Bool = true,
        status: EventStatus = .upcoming,
        cancellationReason: String? = nil,
        isRecurringGenerated: Bool = false,
        parentEventId: UUID? = nil,
        cycleNumber: Int? = nil,
        rsvpDeadline: Date? = nil,
        closedAt: Date? = nil,
        createdBy: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.title = title
        self.coverImageName = coverImageName
        self.coverImageURL = coverImageURL
        self.description = description
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.durationMinutes = durationMinutes
        self.locationName = locationName
        self.locationLat = locationLat
        self.locationLng = locationLng
        self.hostId = hostId
        self.applyRules = applyRules
        self.status = status
        self.cancellationReason = cancellationReason
        self.isRecurringGenerated = isRecurringGenerated
        self.parentEventId = parentEventId
        self.cycleNumber = cycleNumber
        self.rsvpDeadline = rsvpDeadline
        self.closedAt = closedAt
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    /// Tolerant decoder: missing newer columns (e.g. on a fixture from
    /// before 00012 ran) fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                   = try c.decode(UUID.self,   forKey: .id)
        self.groupId              = try c.decode(UUID.self,   forKey: .groupId)
        self.title                = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.coverImageName       = try c.decodeIfPresent(String.self, forKey: .coverImageName)
        self.coverImageURL        = try c.decodeIfPresent(URL.self,    forKey: .coverImageURL)
        self.description          = try c.decodeIfPresent(String.self, forKey: .description)
        self.startsAt             = try c.decode(Date.self,   forKey: .startsAt)
        self.endsAt               = try c.decodeIfPresent(Date.self,   forKey: .endsAt)
        self.durationMinutes      = (try? c.decode(Int.self,  forKey: .durationMinutes)) ?? 180
        self.locationName         = try c.decodeIfPresent(String.self, forKey: .locationName)
        self.locationLat          = try c.decodeIfPresent(Double.self, forKey: .locationLat)
        self.locationLng          = try c.decodeIfPresent(Double.self, forKey: .locationLng)
        self.hostId               = try c.decodeIfPresent(UUID.self,   forKey: .hostId)
        self.applyRules           = (try? c.decode(Bool.self, forKey: .applyRules)) ?? true
        self.status               = (try? c.decode(EventStatus.self, forKey: .status)) ?? .upcoming
        self.cancellationReason   = try c.decodeIfPresent(String.self, forKey: .cancellationReason)
        self.isRecurringGenerated = (try? c.decode(Bool.self, forKey: .isRecurringGenerated)) ?? false
        self.parentEventId        = try c.decodeIfPresent(UUID.self,   forKey: .parentEventId)
        self.cycleNumber          = try c.decodeIfPresent(Int.self,    forKey: .cycleNumber)
        self.rsvpDeadline         = try c.decodeIfPresent(Date.self,   forKey: .rsvpDeadline)
        self.closedAt             = try c.decodeIfPresent(Date.self,   forKey: .closedAt)
        self.createdBy            = try c.decodeIfPresent(UUID.self,   forKey: .createdBy)
        self.createdAt            = try c.decode(Date.self,   forKey: .createdAt)
    }
}

extension Event {
    /// Resolved end date. If `endsAt` missing, derives from `durationMinutes`.
    var resolvedEndsAt: Date {
        endsAt ?? startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    var isPast: Bool {
        status == .closed || status == .cancelled || resolvedEndsAt < .now
    }

    var isHostedBy: (UUID) -> Bool {
        { userId in self.hostId == userId }
    }

    var coverDisplayName: String {
        coverImageName ?? "sunset"  // fallback to first preset
    }
}
