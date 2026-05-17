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
    public let modules: ModuleRegistry

    public init(modules: ModuleRegistry = .v1Fallback) {
        self.modules = modules
    }

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

    /// Resource types the group's template supports.
    /// Reads `template.config.effectiveResourceTypes` only. Constitution §1
    /// art. 6: modules NO declaran resource_types — los types son del
    /// platform. Si en el futuro un grupo necesita habilitar/deshabilitar
    /// types específicos, eso vive en template.config o en group.settings,
    /// no en module manifests.
    /// Falls back to `[.event]` when no template is loaded yet.
    public func availableResourceTypes(for group: Group, template: Template?) -> Set<ResourceType> {
        var out: Set<ResourceType> = []

        if let template {
            out.formUnion(template.config.effectiveResourceTypes)
        }

        // Defensive: V1 groups must always at least have `.event` available
        // since events is the only Resource type with full UI today.
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

    // MARK: - Group sub-tabs

    /// Stable identifiers for the sub-tabs rendered inside the "Grupo" tab.
    /// Mirrors `GroupSubTab.rawValue` in RuulFeatures so the layer that
    /// owns the SwiftUI enum can map back via `rawValue:`. Phase 2 modules
    /// that ship their own group-scoped surface should add to this list,
    /// not invent parallel ids.
    public enum GroupSubTabId {
        public static let overview  = "overview"
        public static let resources = "resources"
        public static let money     = "money"
        public static let members   = "members"
        public static let more      = "more"
    }

    /// Sub-tabs that every group sees regardless of active modules. The
    /// "money" sub-tab is intentionally NOT here — it's gated by ledger
    /// providers so groups without a money capability don't get an empty
    /// tab. Universal set kept stable to avoid layout churn between groups.
    public static let universalGroupSubTabs: [String] = [
        GroupSubTabId.overview,
        GroupSubTabId.resources,
        GroupSubTabId.members,
        GroupSubTabId.more,
    ]

    /// Ordered list of sub-tabs visible in the Grupo tab for this group.
    /// V1 logic: `money` shows when any active module declares the `ledger`
    /// capability block (today: `basic_fines`). Falls back to the universal
    /// set when no group is loaded so the chrome is stable during cold
    /// start. Phase 2+ modules that add new group-scoped surfaces should
    /// register their tab id in `providedTabs` and the V2 implementation
    /// will weave them in here.
    public func availableGroupSubTabs(for group: Group?) -> [String] {
        guard let group else {
            // Pre-load: show the canonical universal set so the bar
            // doesn't pop tabs in once active modules resolve.
            return [
                GroupSubTabId.overview,
                GroupSubTabId.resources,
                GroupSubTabId.money,
                GroupSubTabId.members,
                GroupSubTabId.more,
            ]
        }

        var out: [String] = [GroupSubTabId.overview, GroupSubTabId.resources]
        if moneySubTabEnabled(in: group) {
            out.append(GroupSubTabId.money)
        }
        out.append(GroupSubTabId.members)
        out.append(GroupSubTabId.more)
        return out
    }

    /// Whether the Dinero sub-tab should be visible for `group`. True when
    /// at least one active module provides the `ledger` capability block —
    /// `basic_fines` does, and any group that holds at least one `fund`
    /// resource (live since mig 00139) effectively does too via the
    /// `money` + `ledger` capabilities the FundResourceBuilder auto-enables.
    /// A vanilla "blank" group with no money module / no fund still hides
    /// the empty Dinero tab.
    public func moneySubTabEnabled(in group: Group) -> Bool {
        for moduleId in group.effectiveActiveModules {
            if let module = modules.module(id: moduleId),
               module.providedCapabilityBlocks.contains("ledger") {
                return true
            }
        }
        return false
    }

}
