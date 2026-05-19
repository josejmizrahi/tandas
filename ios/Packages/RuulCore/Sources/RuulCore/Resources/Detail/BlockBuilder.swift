import Foundation

/// Contract every per-source builder implements. Builders are
/// stateless transformations: given a source record + viewer context,
/// return the universal screen tree. They live in RuulFeatures (they
/// touch view-layer concepts like icons and SF symbols), but the
/// protocol lives in RuulCore so RuulCore tests can call them.
public protocol BlockBuilder: Sendable {
    associatedtype Source: Sendable

    func build(
        source: Source,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks
}

/// The slice of viewer state every builder reads. Kept narrow on purpose:
/// builders that need more (e.g. a member directory for RSVP avatars)
/// take it as their own init dependency.
public struct BlockViewerContext: Sendable, Hashable {
    public let userId: UUID?
    public let permissions: Set<Permission>
    /// Group's enabled modules — drives which capability blocks appear.
    public let activeModules: Set<String>
    public let memberId: UUID?  // viewer's group_members.id (when joined)
    public init(
        userId: UUID?, permissions: Set<Permission>,
        activeModules: Set<String>, memberId: UUID?
    ) {
        self.userId = userId; self.permissions = permissions
        self.activeModules = activeModules; self.memberId = memberId
    }
}
