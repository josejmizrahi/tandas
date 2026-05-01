import Foundation

/// One row of `event_attendance`. The Swift model is named `RSVP` (closer
/// to the UI vocabulary) but maps 1:1 to the existing Postgres table.
struct RSVP: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let eventId: UUID
    let userId: UUID
    let status: RSVPStatus
    let respondedAt: Date?
    let cancelledReason: String?
    let arrivedAt: Date?
    let checkInMethod: CheckInMethod?
    let checkInLocationVerified: Bool
    let markedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case eventId                  = "event_id"
        case userId                   = "user_id"
        case status                   = "rsvp_status"
        case respondedAt              = "rsvp_at"
        case cancelledReason          = "cancelled_reason"
        case arrivedAt                = "arrived_at"
        case checkInMethod            = "check_in_method"
        case checkInLocationVerified  = "check_in_location_verified"
        case markedBy                 = "marked_by"
    }

    init(
        id: UUID = UUID(),
        eventId: UUID,
        userId: UUID,
        status: RSVPStatus = .pending,
        respondedAt: Date? = nil,
        cancelledReason: String? = nil,
        arrivedAt: Date? = nil,
        checkInMethod: CheckInMethod? = nil,
        checkInLocationVerified: Bool = false,
        markedBy: UUID? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.userId = userId
        self.status = status
        self.respondedAt = respondedAt
        self.cancelledReason = cancelledReason
        self.arrivedAt = arrivedAt
        self.checkInMethod = checkInMethod
        self.checkInLocationVerified = checkInLocationVerified
        self.markedBy = markedBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                       = try c.decode(UUID.self, forKey: .id)
        self.eventId                  = try c.decode(UUID.self, forKey: .eventId)
        self.userId                   = try c.decode(UUID.self, forKey: .userId)
        self.status                   = (try? c.decode(RSVPStatus.self, forKey: .status)) ?? .pending
        self.respondedAt              = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
        self.cancelledReason          = try c.decodeIfPresent(String.self, forKey: .cancelledReason)
        self.arrivedAt                = try c.decodeIfPresent(Date.self, forKey: .arrivedAt)
        self.checkInMethod            = try c.decodeIfPresent(CheckInMethod.self, forKey: .checkInMethod)
        self.checkInLocationVerified  = (try? c.decode(Bool.self, forKey: .checkInLocationVerified)) ?? false
        self.markedBy                 = try c.decodeIfPresent(UUID.self, forKey: .markedBy)
    }

    var isCheckedIn: Bool { arrivedAt != nil }

    var isAttending: Bool { status == .going }
}
