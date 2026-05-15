import Foundation

/// One row of `public.resource_links` (mig 00198) — a directed link from
/// one resource (e.g. an event) to another (e.g. a space/asset/fund) that
/// the source resource interacts with.
///
/// Append-only per Plans/Active/EventResource.md §17: a row is INSERT'd
/// when the link is created, and `unlinked_at` is stamped on removal.
/// Active link = `unlinkedAt == nil`. Re-linking after unlink produces a
/// new row; the historical row stays for the audit trail.
public struct ResourceLink: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    /// Source resource. v1 always an `event`.
    public let fromResourceId: UUID
    /// Target resource. v1: space, asset, fund, or right.
    public let toResourceId: UUID
    public let linkKind: LinkKind
    public let linkedAt: Date
    public let linkedBy: UUID?
    public let unlinkedAt: Date?
    public let unlinkedBy: UUID?

    public var isActive: Bool { unlinkedAt == nil }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId         = "group_id"
        case fromResourceId  = "from_resource_id"
        case toResourceId    = "to_resource_id"
        case linkKind        = "link_kind"
        case linkedAt        = "linked_at"
        case linkedBy        = "linked_by"
        case unlinkedAt      = "unlinked_at"
        case unlinkedBy      = "unlinked_by"
    }

    public init(
        id: UUID,
        groupId: UUID,
        fromResourceId: UUID,
        toResourceId: UUID,
        linkKind: LinkKind,
        linkedAt: Date,
        linkedBy: UUID? = nil,
        unlinkedAt: Date? = nil,
        unlinkedBy: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.fromResourceId = fromResourceId
        self.toResourceId = toResourceId
        self.linkKind = linkKind
        self.linkedAt = linkedAt
        self.linkedBy = linkedBy
        self.unlinkedAt = unlinkedAt
        self.unlinkedBy = unlinkedBy
    }
}

/// Relation verb on a `resource_links` row. v1 ships `.uses` only —
/// event uses another resource per Plans/Active/EventResource.md §4
/// ("Event puede usar assets, spaces, funds, rights"). Future kinds
/// (`governs`, `generates`) land here as the spec expands.
public enum LinkKind: String, Codable, Sendable, Hashable {
    case uses
}
