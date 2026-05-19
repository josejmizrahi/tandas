import Foundation

/// The full screen tree for a single Resource Detail render. Every
/// `BlockBuilder` returns one of these; the View consumes one of these.
/// The view contains zero per-source branching — that all lives in the
/// builder that produced this value.
public struct ResourceBlocks: Sendable, Hashable {
    /// Layer 1.
    public let identity: IdentityRibbon
    /// Layer 2. Required — every resource has SOME headline (the
    /// resolver guarantees a non-empty string per doctrine §3).
    public let state: StateHeadline
    /// Layer 4. May be empty; renderer hides itself when so.
    public let properties: PropertiesBlock
    /// Layer 5. Ordered by `BlockPriorityResolver`. May include empty
    /// prompts (slim one-liners) for capabilities enabled-but-empty.
    public let capabilities: [CapabilityBlock]
    /// Layer 6. May be empty.
    public let relations: [RelationCard]
    /// Layer 7. Last 5 entries. `hasMore` drives the "Ver más" affordance.
    public let activityHead: [ActivityEntry]
    public let hasMoreActivity: Bool

    public init(
        identity: IdentityRibbon,
        state: StateHeadline,
        properties: PropertiesBlock,
        capabilities: [CapabilityBlock],
        relations: [RelationCard],
        activityHead: [ActivityEntry],
        hasMoreActivity: Bool
    ) {
        self.identity = identity; self.state = state
        self.properties = properties; self.capabilities = capabilities
        self.relations = relations
        self.activityHead = activityHead; self.hasMoreActivity = hasMoreActivity
    }
}
