import Foundation

/// Polymorphic input to the per-resource Money surface. Mirrors
/// `ResourceRuleContext` — lets a single ledger coordinator drive
/// money flows for any Resource (event, asset, fund, trip, …) without
/// per-type plumbing.
///
/// Founder framing 2026-05-10: ResourceDetail is capability-driven. The
/// "Money" section is just another capability section; the underlying
/// coordinator should not care whether it's wired to an event or a
/// house-share asset.
public struct ResourceLedgerContext: Sendable, Hashable {
    public let groupId: UUID
    public let resourceId: UUID
    /// Raw `resource_type` string. Used for analytics / display copy
    /// ("movimientos de esta cena" vs "movimientos de esta casa") and
    /// reserved for future scope filters.
    public let resourceType: String
    /// User-facing name (event title, asset name, fund label) shown in
    /// the sheet header.
    public let displayName: String
    /// Current user's auth id. The coordinator resolves this to a
    /// `group_members.id` via the directory loaded with the entries.
    public let currentUserId: UUID

    public init(
        groupId: UUID,
        resourceId: UUID,
        resourceType: String,
        displayName: String,
        currentUserId: UUID
    ) {
        self.groupId = groupId
        self.resourceId = resourceId
        self.resourceType = resourceType
        self.displayName = displayName
        self.currentUserId = currentUserId
    }
}
