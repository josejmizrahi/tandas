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

/// Relation verb on a `resource_links` row. The V1 catalog (8 kinds)
/// matches the SQL `resource_link_kinds` table per
/// `Plans/Active/ResourceLinks.md §3`. Raw values are snake_case to
/// match the SQL column verbatim.
///
/// **Doctrinal note (`owns` vs `right`)**: `owns` connects two
/// resources (e.g. `fund owns asset`). Human ownership lives via
/// `right.holder_member_id`. The two never collide; do not use
/// `owns` to model member↔resource ties.
public enum LinkKind: String, Codable, Sendable, Hashable, CaseIterable {
    case uses
    case funds
    case governs
    case locatedIn      = "located_in"
    case scheduledIn    = "scheduled_in"
    case reserves
    case grantsAccessTo = "grants_access_to"
    case owns

    /// Spanish label for the picker / details UI. Source of truth lives
    /// here so the wizard doesn't have to know SQL slugs.
    public var displayName: String {
        switch self {
        case .uses:            return "Usa"
        case .funds:           return "Financia"
        case .governs:         return "Gobierna"
        case .locatedIn:       return "Ubicado en"
        case .scheduledIn:     return "Ocurre en"
        case .reserves:        return "Reserva"
        case .grantsAccessTo:  return "Da acceso a"
        case .owns:            return "Es dueño de"
        }
    }

    /// Validation matrix mirrored from `public.resource_link_kinds`
    /// (mig 00232). Used by the iOS picker so invalid tuples never
    /// reach the server. Server-side enforces the same catalog as
    /// the safety net.
    public func isValid(from: ResourceType, to: ResourceType) -> Bool {
        switch self {
        case .uses:
            return (from == .event && [.asset, .fund, .slot, .space].contains(to))
                || (from == .fund  && [.asset, .space].contains(to))
        case .funds:
            return from == .fund && [.asset, .event, .space].contains(to)
        case .governs:
            return from == .right && [.asset, .fund, .slot, .space].contains(to)
        case .locatedIn:
            return [.asset, .slot].contains(from) && to == .space
        case .scheduledIn:
            return [.event, .slot].contains(from) && to == .space
        case .reserves:
            return from == .slot && [.asset, .space].contains(to)
        case .grantsAccessTo:
            return from == .right && [.asset, .slot, .space].contains(to)
        case .owns:
            return from == .fund && [.asset, .space].contains(to)
        }
    }

    /// Convenience: the set of LinkKinds that COULD apply when the
    /// caller knows only the `from` type (e.g. asset's "+ Vincular"
    /// picker). The actual target resource still needs to satisfy
    /// `isValid(from:to:)`.
    public static func candidates(from: ResourceType) -> [LinkKind] {
        allCases.filter { kind in
            ResourceType.allCases.contains { to in kind.isValid(from: from, to: to) }
        }
    }
}
