import Foundation

/// Append-only atom: a booking claim placed on a slot resource. Mig 00216.
///
/// Doctrine — Constitution §15 separates **Resource** (object) from
/// **Action** (atom). A booking is an action: someone claimed a slot at
/// some moment. The claim itself is immutable. Cancellation /
/// expiration record additional `system_events` rows (`bookingCancelled`,
/// `bookingExpired`); the projection joins to derive current status.
///
/// Pre-mig 00216 the wire shape was `resources WHERE resource_type='booking'`,
/// which violated mig 00147's frozen resource_type CHECK and broke
/// `book_slot` end-to-end. Booking now lives in `public.bookings` —
/// guarded by `bookings_atom_guard` against UPDATE / DELETE.
public struct Booking: Atom, Hashable {
    public static var atomTableName: String { "bookings" }

    public let id: UUID
    public let groupId: UUID
    public let slotId: UUID
    public let memberId: UUID
    public let metadata: JSONConfig
    public let createdAt: Date
    public let createdBy: UUID?

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        slotId: UUID,
        memberId: UUID,
        metadata: JSONConfig = .object([:]),
        createdAt: Date = .now,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.slotId = slotId
        self.memberId = memberId
        self.metadata = metadata
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    public enum CodingKeys: String, CodingKey {
        case id, metadata
        case groupId    = "group_id"
        case slotId     = "slot_id"
        case memberId   = "member_id"
        case createdAt  = "created_at"
        case createdBy  = "created_by"
    }
}
