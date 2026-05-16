import Foundation

/// Typed view of `public.resources WHERE resource_type='slot'` (mig 00070
/// for the underlying RPC, mig 00204 for the wizard branch).
///
/// A `Slot` is a usage window of a parent asset (turno, asiento, horario,
/// fin de semana). Its identity is `(asset_id, starts_at, ends_at)` and
/// its lifecycle status moves through `unassigned → assigned → booked`
/// via the lifecycle RPCs (`assign_slot`, `book_slot`, `request_slot_swap`).
///
/// Doctrine: there is no `slots` table — slot lives polymorphically in
/// `resources.metadata`. This struct exists for ergonomics, not schema
/// parallelism.
public struct Slot: Resource, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let assetId: UUID
    public let startsAt: Date
    public let endsAt: Date
    public let assignedMemberId: UUID?
    public let bookingId: UUID?
    public let status: String
    public let createdBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    public let archivedAt: Date?

    public var resourceType: ResourceType { .slot }
    public var resourceStatus: String { status }
    public var isArchived: Bool { archivedAt != nil }

    /// True when the slot still has no holder. Lifecycle gate for `assign_slot`
    /// (mig 00070 — only `unassigned` slots may be assigned).
    public var isUnassigned: Bool { status == "unassigned" }

    /// True when the slot has been claimed via `book_slot` (mig 00070).
    public var isBooked: Bool { bookingId != nil }

    public init(
        id: UUID,
        groupId: UUID,
        assetId: UUID,
        startsAt: Date,
        endsAt: Date,
        assignedMemberId: UUID? = nil,
        bookingId: UUID? = nil,
        status: String = "unassigned",
        createdBy: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.assetId = assetId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.assignedMemberId = assignedMemberId
        self.bookingId = bookingId
        self.status = status
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

public extension ResourceRow {
    /// Decodes a `ResourceRow` with `resource_type == .slot` into a typed
    /// `Slot`. Mirrors `decodeAsEvent` / `decodeAsSpace` — throws on type
    /// mismatch or missing required metadata.
    func decodeAsSlot() throws -> Slot {
        guard resourceType == .slot else {
            throw ResourceRowError.typeMismatch(expected: .slot, got: resourceType)
        }
        guard let assetIdRaw = metadata["asset_id"]?.stringValue,
              let assetId = UUID(uuidString: assetIdRaw) else {
            throw ResourceRowError.missingMetadataKey("asset_id")
        }
        guard let startsRaw = metadata["starts_at"]?.stringValue,
              let startsAt = Self.parseSlotISO8601(startsRaw) else {
            throw ResourceRowError.missingMetadataKey("starts_at")
        }
        guard let endsRaw = metadata["ends_at"]?.stringValue,
              let endsAt = Self.parseSlotISO8601(endsRaw) else {
            throw ResourceRowError.missingMetadataKey("ends_at")
        }

        let assignedMemberId = (metadata["assigned_member_id"]?.stringValue).flatMap(UUID.init(uuidString:))
        let bookingId = (metadata["booking_id"]?.stringValue).flatMap(UUID.init(uuidString:))

        return Slot(
            id: id,
            groupId: groupId,
            assetId: assetId,
            startsAt: startsAt,
            endsAt: endsAt,
            assignedMemberId: assignedMemberId,
            bookingId: bookingId,
            status: status,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt
        )
    }

    /// Tolerant ISO8601 parser shared by slot decode paths. Mirrors the
    /// fractional/plain split that `decodeAsEvent` uses.
    fileprivate static func parseSlotISO8601(_ s: String) -> Date? {
        if let d = Self.slotIso8601Frac.date(from: s) { return d }
        return Self.slotIso8601Plain.date(from: s)
    }

    fileprivate nonisolated(unsafe) static let slotIso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    fileprivate nonisolated(unsafe) static let slotIso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
