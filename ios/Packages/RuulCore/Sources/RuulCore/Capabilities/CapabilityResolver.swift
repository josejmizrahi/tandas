import Foundation

/// Resolves runtime capabilities for a group based on its
/// `Template` + `activeModules` + `governance`.
///
/// This is the single seam between the static V1 enum-driven UI (hardcoded
/// 4 tabs, hardcoded "fines visible") and the Phase 2+ data-driven runtime
/// (tabs come from template, features gate by module activation). For V1
/// the resolver returns the same answers the hardcoded code would; the
/// scaffolding is there so views and coordinators can adopt it
/// incrementally without further refactor when modular activation lands.
///
/// **Not a replacement for `GovernanceService`**. This resolver answers
/// "is the surface available" (e.g. is the fines tab visible?). The
/// governance service answers "can THIS user perform THIS action right
/// now?" (e.g. can Bob issue a fine?). They compose:
///
/// ```
/// guard capabilityResolver.finesEnabled(in: group) else { return }     // surface
/// let decision = await governance.canPerform(.issueManualFine, ...)    // permission
/// ```
public struct CapabilityResolver: Sendable {
    public init() {}

    // MARK: - Module checks

    /// Whether `moduleId` is in the group's active modules list.
    public func isModuleActive(_ moduleId: String, in group: Group) -> Bool {
        group.effectiveActiveModules.contains(moduleId)
    }

    /// Whether basic monetary fines are enabled for the group.
    public func finesEnabled(in group: Group) -> Bool {
        isModuleActive(GroupModule.basicFines.id, in: group)
    }

    /// Whether the appeal-voting flow is available (requires basic_fines + appeal_voting).
    public func appealsEnabled(in group: Group) -> Bool {
        isModuleActive(GroupModule.appealVoting.id, in: group)
            && finesEnabled(in: group)
    }

    /// Whether RSVP UI is available.
    public func rsvpEnabled(in group: Group) -> Bool {
        isModuleActive(GroupModule.rsvp.id, in: group)
    }

    /// Whether check-in UI is available.
    public func checkInEnabled(in group: Group) -> Bool {
        isModuleActive(GroupModule.checkIn.id, in: group)
    }

    /// Whether host rotation UI is available.
    public func rotationEnabled(in group: Group) -> Bool {
        isModuleActive(GroupModule.rotatingHost.id, in: group)
    }

    // MARK: - Resource types

    /// Resource types the group's active modules + template support.
    /// Combines `template.config.effectiveResourceTypes` (declared support
    /// with `[.event]` default for templates that predate the resourceTypes
    /// field) with `module.providedResourceTypes` for each active module.
    /// Falls back to `[.event]` when no template is loaded yet.
    public func availableResourceTypes(for group: Group, template: Template?) -> Set<ResourceType> {
        var out: Set<ResourceType> = []

        if let template {
            out.formUnion(template.config.effectiveResourceTypes)
        }

        for moduleId in group.effectiveActiveModules {
            if let module = ModuleRegistry.module(id: moduleId) {
                out.formUnion(module.providedResourceTypes)
            }
        }

        // Defensive: V1 groups must always at least have `.event` available
        // since `events` is the only Resource type with full UI today.
        if out.isEmpty {
            out.insert(.event)
        }
        return out
    }

    /// Whether the group can host resources of the given type.
    public func supports(
        resourceType: ResourceType,
        in group: Group,
        template: Template?
    ) -> Bool {
        availableResourceTypes(for: group, template: template).contains(resourceType)
    }

    // MARK: - Tabs

    /// Ordered list of `TabConfig` to render in `MainTabView` for this
    /// group. V1 templates declare 4 universal tabs in
    /// `template.config.suggestedTabs`; Phase 2+ may filter by module
    /// activation (e.g. drop the "Reglas" tab if `basic_fines` is off).
    ///
    /// When a template hasn't loaded yet (cold start before
    /// `TemplateRegistry.refresh()` completes), the resolver falls back to
    /// the canonical V1 4-tab set so MainTabView always has something to
    /// render.
    public func availableTabs(
        for group: Group?,
        template: Template?
    ) -> [TabConfig] {
        if let suggested = template?.config.suggestedTabs, !suggested.isEmpty {
            // For V1 every suggested tab is `isUniversal=true`; module
            // gating arrives in Phase 2 when non-universal tabs appear.
            // Today we just sort by `order` and return.
            let visible = suggested.filter { tab in
                tab.isUniversal || tabIsActiveForGroup(tab, in: group)
            }
            return visible.sorted { $0.order < $1.order }
        }

        // Fallback when template isn't loaded yet OR template doesn't
        // declare suggestedTabs (legacy templates pre-00021).
        return CapabilityResolver.fallbackV1Tabs
    }

    /// Whether a non-universal tab is wired up for the given group's
    /// active modules. V1 has no non-universal tabs so this is unreachable.
    /// Phase 2+ may have e.g. a "Slots" tab gated by `slot_assignment`.
    private func tabIsActiveForGroup(_ tab: TabConfig, in group: Group?) -> Bool {
        guard let group else { return false }
        // Convention: a non-universal tab's `id` matches the module that
        // provides it (e.g. tab id "slots" → module "slot_assignment"
        // declares `providedTabs: ["slots"]`).
        for moduleId in group.effectiveActiveModules {
            if let module = ModuleRegistry.module(id: moduleId),
               module.providedTabs.contains(tab.id) {
                return true
            }
        }
        return false
    }

    /// Canonical V1 4-tab fallback when no template is loaded. Mirrors
    /// `MainTabView.Tab` enum exactly; updates here must keep parity until
    /// Phase 2 ships dynamic rendering.
    public static let fallbackV1Tabs: [TabConfig] = [
        TabConfig(
            id: "home",
            title: "Inicio",
            icon: "house.fill",
            order: 0,
            viewType: "home",
            isUniversal: true
        ),
        TabConfig(
            id: "group",
            title: "Grupo",
            icon: "person.3.fill",
            order: 1,
            viewType: "group",
            isUniversal: true
        ),
        TabConfig(
            id: "history",
            title: "Historial",
            icon: "clock.arrow.circlepath",
            order: 2,
            viewType: "history",
            isUniversal: true
        ),
        TabConfig(
            id: "settings",
            title: "Ajustes",
            icon: "gear",
            order: 3,
            viewType: "settings",
            isUniversal: true
        ),
    ]
}
