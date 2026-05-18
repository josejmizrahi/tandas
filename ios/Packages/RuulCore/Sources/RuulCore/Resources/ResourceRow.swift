import Foundation

/// One row of `public.resources`. Polymorphic envelope: any concrete
/// resource (event, slot, fund, position, asset, contribution) lands
/// here with its domain-specific fields living in `metadata` jsonb.
///
/// The `resources` table is populated by the dual-write trigger
/// `events_sync_to_resources` (migration 00039) for V1 events, and
/// directly by future resource-type-specific creation paths in V2+.
///
/// `ResourceRow.id == public.resources.id`. For V1 events,
/// `ResourceRow.id == events.id` by trigger design.
public struct ResourceRow: Resource, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let resourceType: ResourceType
    public let status: String
    public let metadata: JSONConfig
    public let createdBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    /// Soft-delete timestamp (mig 00184). Non-nil = archived; the row is
    /// hidden from default member SELECTs and surfaced only to the
    /// group's founder for restore via `unarchive_resource`.
    public let archivedAt: Date?

    public enum CodingKeys: String, CodingKey {
        case id, status, metadata
        case groupId        = "group_id"
        case resourceType   = "resource_type"
        case createdBy      = "created_by"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
        case archivedAt     = "archived_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        resourceType: ResourceType,
        status: String,
        metadata: JSONConfig = .empty,
        createdBy: UUID? = nil,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceType = resourceType
        self.status = status
        self.metadata = metadata
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    /// Tolerant decoder: missing `metadata` falls back to `.empty`,
    /// missing `updated_at` falls back to `created_at` (e.g. a row
    /// projected from a non-trigger source pre-cohabitation).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id            = try c.decode(UUID.self,   forKey: .id)
        self.groupId       = try c.decode(UUID.self,   forKey: .groupId)
        self.resourceType  = try c.decode(ResourceType.self, forKey: .resourceType)
        self.status        = try c.decode(String.self, forKey: .status)
        self.metadata      = (try? c.decode(JSONConfig.self, forKey: .metadata)) ?? .empty
        self.createdBy     = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        let createdAt      = try c.decode(Date.self, forKey: .createdAt)
        self.createdAt     = createdAt
        self.updatedAt     = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        self.archivedAt    = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    /// `Resource.resourceStatus` requirement. The wire column is `status`;
    /// this passthrough lets `ResourceRow` wear the polymorphic protocol
    /// without duplicating storage.
    public var resourceStatus: String { status }

    /// True when `archived_at` is set. UI hides such resources from active
    /// lists; only the founder can see + restore them.
    public var isArchived: Bool { archivedAt != nil }
}

extension ResourceRow {
    /// Member-row id of the current holder for a `right` resource. Reads
    /// `metadata.holder_member_id` (populated by `create_right` alongside
    /// `holder_user_id`). Returns nil for non-right resources or when
    /// the metadata key is missing / unparseable.
    ///
    /// Used by `RightActionSheet` to filter the transfer recipient picker
    /// so the current holder isn't offered as a self-transfer target.
    /// Lives on the model so the view layer stays type-agnostic — per
    /// ontology constitution Rule 6 ("UI siempre capability-driven; cero
    /// switch resource_type en routing").
    public var rightHolderMemberId: UUID? {
        guard resourceType == .right,
              let raw = metadata["holder_member_id"]?.stringValue,
              !raw.isEmpty,
              let id = UUID(uuidString: raw)
        else { return nil }
        return id
    }
}

