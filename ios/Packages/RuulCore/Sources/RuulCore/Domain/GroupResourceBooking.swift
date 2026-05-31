import Foundation

/// V3 Resources Deep — Fase B.3. Booking row returned by
/// `list_bookings_for_resource(...)`. Status whitelist:
/// `requested | confirmed | cancelled | no_show | completed`.
public struct GroupResourceBooking: Identifiable, Decodable, Sendable, Hashable {
    public let id: UUID
    public let resourceId: UUID
    public let groupId: UUID
    public let bookedByMembershipId: UUID?
    public let startsAt: Date
    public let endsAt: Date?
    public let status: Status
    public let reason: String?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resourceId            = "resource_id"
        case groupId               = "group_id"
        case bookedByMembershipId  = "booked_by_membership_id"
        case startsAt              = "starts_at"
        case endsAt                = "ends_at"
        case status
        case reason
        case createdAt             = "created_at"
    }

    public enum Status: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
        case requested
        case confirmed
        case cancelled
        case noShow    = "no_show"
        case completed

        public var id: String { rawValue }

        public var label: LocalizedStringResource {
            switch self {
            case .requested: return L10n.Bookings.statusRequested
            case .confirmed: return L10n.Bookings.statusConfirmed
            case .cancelled: return L10n.Bookings.statusCancelled
            case .noShow:    return L10n.Bookings.statusNoShow
            case .completed: return L10n.Bookings.statusCompleted
            }
        }
    }

    public init(
        id: UUID,
        resourceId: UUID,
        groupId: UUID,
        bookedByMembershipId: UUID? = nil,
        startsAt: Date,
        endsAt: Date? = nil,
        status: Status = .confirmed,
        reason: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.resourceId = resourceId
        self.groupId = groupId
        self.bookedByMembershipId = bookedByMembershipId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.reason = reason
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                  = try c.decode(UUID.self, forKey: .id)
        self.resourceId          = try c.decode(UUID.self, forKey: .resourceId)
        self.groupId             = try c.decode(UUID.self, forKey: .groupId)
        self.bookedByMembershipId = try c.decodeIfPresent(UUID.self, forKey: .bookedByMembershipId)
        self.startsAt            = try c.decode(Date.self, forKey: .startsAt)
        self.endsAt              = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        let rawStatus            = try c.decode(String.self, forKey: .status)
        self.status              = Status(rawValue: rawStatus) ?? .confirmed
        self.reason              = try c.decodeIfPresent(String.self, forKey: .reason)
        self.createdAt           = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}
