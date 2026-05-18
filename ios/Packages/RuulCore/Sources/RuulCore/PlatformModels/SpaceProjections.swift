import Foundation

/// Typed views of the canonical space projections (mig 00267).
///
/// Per Plans/Active/Space.md §10, space state is **derived** — these
/// types deserialize the views, never persist independent truth. UI
/// fetches via `SpaceProjectionRepository`; refresh is kick-based off
/// realtime atoms (`bookingCreated`, `space*`, `checkInRecorded`).

// MARK: - Availability

/// One active booking on a space within its time window. Mirrors
/// `public.space_availability_view`. `startsAt` / `endsAt` may both be
/// nil for open-ended claims (the row is still active until cancelled
/// or expired).
public struct SpaceAvailabilityRow: Projection, Hashable {
    public static var projectionViewName: String { "space_availability_view" }

    public let bookingId: UUID
    public let spaceId: UUID
    public let groupId: UUID
    public let memberId: UUID
    public let startsAt: Date?
    public let endsAt: Date?
    public let notes: String?
    public let bookedAt: Date

    public init(
        bookingId: UUID,
        spaceId: UUID,
        groupId: UUID,
        memberId: UUID,
        startsAt: Date?,
        endsAt: Date?,
        notes: String?,
        bookedAt: Date
    ) {
        self.bookingId = bookingId
        self.spaceId = spaceId
        self.groupId = groupId
        self.memberId = memberId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.notes = notes
        self.bookedAt = bookedAt
    }

    public enum CodingKeys: String, CodingKey {
        case notes
        case bookingId  = "booking_id"
        case spaceId    = "space_id"
        case groupId    = "group_id"
        case memberId   = "member_id"
        case startsAt   = "starts_at"
        case endsAt     = "ends_at"
        case bookedAt   = "booked_at"
    }
}

// MARK: - Capacity

/// Per-space capacity snapshot. Mirrors `public.space_capacity_view`.
/// `capacity` nil = unlimited (`isFull` always false in that case).
public struct SpaceCapacityRow: Projection, Hashable {
    public static var projectionViewName: String { "space_capacity_view" }

    public let spaceId: UUID
    public let groupId: UUID
    public let capacity: Int?
    public let activeBookings: Int
    public let waitlistCount: Int
    public let isFull: Bool

    public init(
        spaceId: UUID,
        groupId: UUID,
        capacity: Int?,
        activeBookings: Int,
        waitlistCount: Int,
        isFull: Bool
    ) {
        self.spaceId = spaceId
        self.groupId = groupId
        self.capacity = capacity
        self.activeBookings = activeBookings
        self.waitlistCount = waitlistCount
        self.isFull = isFull
    }

    public var remaining: Int? {
        guard let capacity else { return nil }
        return max(0, capacity - activeBookings)
    }

    public enum CodingKeys: String, CodingKey {
        case capacity
        case spaceId        = "space_id"
        case groupId        = "group_id"
        case activeBookings = "active_bookings"
        case waitlistCount  = "waitlist_count"
        case isFull         = "is_full"
    }
}

// MARK: - Occupancy

/// One member currently considered "inside" a space. Mirrors
/// `public.space_occupancy_view`. Each row is the latest check-in for
/// the (space, member) pair; future release atoms (Phase 2 follow-up)
/// will auto-expire occupants.
public struct SpaceOccupancyRow: Projection, Hashable {
    public static var projectionViewName: String { "space_occupancy_view" }

    public let spaceId: UUID
    public let memberId: UUID
    public let lastCheckInActionId: UUID
    public let checkedInAt: Date
    public let bookingId: UUID?
    public let notes: String?
    public let groupId: UUID

    public init(
        spaceId: UUID,
        memberId: UUID,
        lastCheckInActionId: UUID,
        checkedInAt: Date,
        bookingId: UUID?,
        notes: String?,
        groupId: UUID
    ) {
        self.spaceId = spaceId
        self.memberId = memberId
        self.lastCheckInActionId = lastCheckInActionId
        self.checkedInAt = checkedInAt
        self.bookingId = bookingId
        self.notes = notes
        self.groupId = groupId
    }

    public enum CodingKeys: String, CodingKey {
        case notes
        case spaceId             = "space_id"
        case memberId            = "member_id"
        case lastCheckInActionId = "last_check_in_action_id"
        case checkedInAt         = "checked_in_at"
        case bookingId           = "booking_id"
        case groupId             = "group_id"
    }
}

// MARK: - History

/// One entry in the space activity feed. Mirrors `public.space_history_view`.
/// Wraps a `SystemEvent`-shaped row scoped to space-relevant atoms.
public struct SpaceHistoryRow: Projection, Hashable {
    public static var projectionViewName: String { "space_history_view" }

    public let eventId: UUID
    public let spaceId: UUID
    public let groupId: UUID
    public let eventType: SystemEventType
    public let memberId: UUID?
    public let payload: JSONConfig
    public let occurredAt: Date

    public init(
        eventId: UUID,
        spaceId: UUID,
        groupId: UUID,
        eventType: SystemEventType,
        memberId: UUID?,
        payload: JSONConfig,
        occurredAt: Date
    ) {
        self.eventId = eventId
        self.spaceId = spaceId
        self.groupId = groupId
        self.eventType = eventType
        self.memberId = memberId
        self.payload = payload
        self.occurredAt = occurredAt
    }

    public enum CodingKeys: String, CodingKey {
        case payload
        case eventId    = "event_id"
        case spaceId    = "space_id"
        case groupId    = "group_id"
        case eventType  = "event_type"
        case memberId   = "member_id"
        case occurredAt = "occurred_at"
    }
}
