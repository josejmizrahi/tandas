import Foundation

/// Polymorphic input to the resource-rules surface. Lets a single
/// coordinator + sheet stack drive rules for any Resource — events,
/// assets, funds, slots — without per-type plumbing in iOS.
///
/// Founder framing 2026-05-10: rules apply to any Resource. The shape
/// of the rules UI doesn't change with the resource type; only the
/// label + the authorization predicate do.
public struct ResourceRuleContext: Sendable, Hashable {
    public let groupId: UUID
    public let resourceId: UUID
    /// Raw resource_type string ("event", "asset", "fund", …). Used by
    /// the catalog filter so triggers/consequences only specific to a
    /// type stay hidden when irrelevant.
    public let resourceType: String
    /// User-facing name rendered in the sheet header.
    public let displayName: String
    /// Pre-resolved authorization. `true` when the current user is a
    /// group admin OR (when the resource is an event) the event host.
    /// Mirrors the server-side gate in `create_resource_rule` so the
    /// CTA stays hidden for users who'd hit "permission denied".
    public let canCreate: Bool

    public init(
        groupId: UUID,
        resourceId: UUID,
        resourceType: String,
        displayName: String,
        canCreate: Bool
    ) {
        self.groupId = groupId
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.displayName = displayName
        self.canCreate = canCreate
    }
}
