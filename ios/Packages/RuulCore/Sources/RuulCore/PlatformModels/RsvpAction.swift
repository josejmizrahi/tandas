import Foundation

/// RSVP atom per OpenPlatform Taxonomy §2.C.
///
/// Append-only audit trail for RSVP changes. Replaces the previous mutable
/// `event_attendance.rsvp_status` column as the source of truth — that
/// column becomes a projection (latest action per (resource, member))
/// derived from this table.
///
/// Schema source: mig 00078. Decodes from `public.rsvp_actions`.
public struct RsvpAction: Atom, Hashable {
    public static var atomTableName: String { "rsvp_actions" }

    public let id: UUID
    public let resourceId: UUID
    public let memberId: UUID
    public let status: String
    public let recordedAt: Date
    public let metadata: JSONConfig

    public init(
        id: UUID = UUID(),
        resourceId: UUID,
        memberId: UUID,
        status: String,
        recordedAt: Date = .now,
        metadata: JSONConfig = .object([:])
    ) {
        self.id = id
        self.resourceId = resourceId
        self.memberId = memberId
        self.status = status
        self.recordedAt = recordedAt
        self.metadata = metadata
    }

    public enum CodingKeys: String, CodingKey {
        case id, status, metadata
        case resourceId  = "resource_id"
        case memberId    = "member_id"
        case recordedAt  = "recorded_at"
    }

    /// Canonical RSVP status values. String-typed for forward-compat.
    public enum Status {
        public static let going    = "going"
        public static let maybe    = "maybe"
        public static let declined = "declined"
        public static let pending  = "pending"
    }
}
