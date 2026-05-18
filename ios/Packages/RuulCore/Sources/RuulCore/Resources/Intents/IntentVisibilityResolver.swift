import Foundation

/// Inputs the visibility resolver consults to decide whether a single
/// `ResourceIntent` should be shown on the post-create screen (or any
/// other intent surface). Doctrine 2026-05-18: an intent that fails any
/// gate is HIDDEN, never greyed — greying invites the "why?" question
/// that exposes governance plumbing.
public struct IntentVisibilityContext: Sendable {
    public let resourceType: ResourceType
    public let group: Group
    /// Capability ids already enabled on the just-created resource —
    /// populated from `ResourceCreationCoordinator.attachedCapabilities`
    /// (which itself mirrors `ResourceCreationResult.enabledCapabilityIds`).
    public let attachedCapabilities: Set<String>
    /// Permissions the current viewer holds. Caller resolves these from
    /// the group's role catalog + the viewer's `member.rawRoles`. The
    /// resolver only consults them — it doesn't perform the lookup.
    public let viewerPermissions: Set<Permission>

    public init(
        resourceType: ResourceType,
        group: Group,
        attachedCapabilities: Set<String>,
        viewerPermissions: Set<Permission>
    ) {
        self.resourceType = resourceType
        self.group = group
        self.attachedCapabilities = attachedCapabilities
        self.viewerPermissions = viewerPermissions
    }
}

/// Decides whether an intent is visible to the viewer given the
/// resource state. Pure function — no I/O, no side effects.
///
/// Visibility gates, in order (fail-fast):
///   1. `resourceTypes` contains the resource's type
///   2. Every `permissionsRequired` is held by the viewer
///   3. Every `requiredCapability` is either already attached OR
///      activatable (catalog has it as `.stable` AND resolver says
///      the group's active modules provide it for the type). Already-
///      attached caps cover the silent-attach case; activatable caps
///      cover the lazy-attach-on-tap case the dispatcher will trigger.
///
/// "Hidden not greyed" doctrine: anything that fails returns `false`
/// here; the screen never renders the row. There is no `.disabled`
/// state.
public struct IntentVisibilityResolver: Sendable {
    public let catalog: CapabilityCatalog
    public let resolver: CapabilityResolver

    public init(
        catalog: CapabilityCatalog = .v1,
        resolver: CapabilityResolver = CapabilityResolver()
    ) {
        self.catalog = catalog
        self.resolver = resolver
    }

    public func isVisible(_ intent: ResourceIntent, in ctx: IntentVisibilityContext) -> Bool {
        guard intent.resourceTypes.contains(ctx.resourceType) else { return false }

        for perm in intent.permissionsRequired {
            if !ctx.viewerPermissions.contains(perm) { return false }
        }

        if !intent.requiredCapabilities.isEmpty {
            let available = Set(resolver.availableCapabilities(
                for: ctx.resourceType, in: ctx.group, catalog: catalog
            ))
            for capId in intent.requiredCapabilities {
                if ctx.attachedCapabilities.contains(capId) { continue }
                guard let block = catalog[capId], block.status.isStable else {
                    return false
                }
                guard available.contains(capId) else { return false }
            }
        }

        return true
    }

    /// Bulk filter — preserves the input order so callers driving an
    /// ordered grid (variant.suggestedIntents → IntentRegistry lookup
    /// → this filter) keep their layout intent intact.
    public func visible(_ intents: [ResourceIntent], in ctx: IntentVisibilityContext) -> [ResourceIntent] {
        intents.filter { isVisible($0, in: ctx) }
    }
}
