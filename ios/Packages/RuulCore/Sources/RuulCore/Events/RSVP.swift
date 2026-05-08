import Foundation

/// One row of `event_attendance`. The Swift model is named `RSVP` (closer
/// to the UI vocabulary) but maps 1:1 to the existing Postgres table.
public struct RSVP: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let eventId: UUID
    public let userId: UUID
    public let status: RSVPStatus
    public let respondedAt: Date?
    public let cancelledReason: String?
    public let arrivedAt: Date?
    public let checkInMethod: CheckInMethod?
    public let checkInLocationVerified: Bool
    public let markedBy: UUID?
    /// Extra guests this member is bringing. 0 = just themselves.
    public let plusOnes: Int
    /// 1-based position on the waitlist; nil unless `status == .waitlisted`.
    public let waitlistPosition: Int?

    public enum CodingKeys: String, CodingKey {
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
        case plusOnes                 = "plus_ones"
        case waitlistPosition         = "waitlist_position"
    }

    public init(
        id: UUID = UUID(),
        eventId: UUID,
        userId: UUID,
        status: RSVPStatus = .pending,
        respondedAt: Date? = nil,
        cancelledReason: String? = nil,
        arrivedAt: Date? = nil,
        checkInMethod: CheckInMethod? = nil,
        checkInLocationVerified: Bool = false,
        markedBy: UUID? = nil,
        plusOnes: Int = 0,
        waitlistPosition: Int? = nil
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
        self.plusOnes = plusOnes
        self.waitlistPosition = waitlistPosition
    }

    public init(from decoder: Decoder) throws {
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
        self.plusOnes                 = (try? c.decode(Int.self, forKey: .plusOnes)) ?? 0
        self.waitlistPosition         = try c.decodeIfPresent(Int.self, forKey: .waitlistPosition)
    }

    public var isCheckedIn: Bool { arrivedAt != nil }

    public var isAttending: Bool { status == .going }

    /// Total seats this member occupies (1 + their plus-ones).
    public var seatCount: Int { 1 + plusOnes }
}
