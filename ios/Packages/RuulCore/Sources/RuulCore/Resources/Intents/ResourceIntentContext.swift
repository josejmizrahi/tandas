import Foundation

/// Snapshot of "what the registry needs to filter intents right now."
///
/// Built by the consumer surface (resource detail toolbar, post-create
/// screen, empty-state CTA) before calling
/// `ResourceIntentRegistry.available(in:)`. Includes both static facts
/// (the resource, the group, the viewer's permissions) and dynamic
/// state (`resource.metadata`, `enabledCapabilities`) that the runtime
/// gate consults to hide intents that would fail server-side.
///
/// Sendable so it can cross actors freely — none of the carried values
/// own reference state.
public struct ResourceIntentContext: Sendable {
    /// The resource the user is acting on.
    public let resource: ResourceRow

    /// The owning group. Used by the post-create flow to check
    /// `groups.active_modules`; the toolbar uses it for member-directory
    /// lookups indirectly via `viewerPermissions`.
    public let group: Group

    /// `auth.users.id` of the viewer, when authenticated. Optional so
    /// signed-out / loading states don't trap.
    public let viewerUserId: UUID?

    /// Permission set the viewer's roles grant (union across all rawRoles
    /// resolved against `group.effectiveRoles`). Already computed by the
    /// caller so the gate doesn't re-walk the catalog per intent.
    public let viewerPermissions: Set<Permission>

    /// Capability ids currently enabled on this resource. The toolbar
    /// path requires these to be a superset of `intent.requiredCapabilities`;
    /// the post-create path is laxer (it calls `LazyCapabilityActivator`
    /// to bring missing-but-available caps online).
    public let enabledCapabilities: Set<String>

    public init(
        resource: ResourceRow,
        group: Group,
        viewerUserId: UUID?,
        viewerPermissions: Set<Permission>,
        enabledCapabilities: Set<String>
    ) {
        self.resource = resource
        self.group = group
        self.viewerUserId = viewerUserId
        self.viewerPermissions = viewerPermissions
        self.enabledCapabilities = enabledCapabilities
    }
}
