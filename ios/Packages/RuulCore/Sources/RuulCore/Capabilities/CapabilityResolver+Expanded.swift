import Foundation

/// Expanded capability-aware methods per OpenPlatform Taxonomy §E.
///
/// These methods compose three signals:
///   1. `groups.active_modules`  — what modules the group has opted in.
///   2. `modules.provided_capability_blocks` — what blocks each active
///      module provides (read from `CapabilityCatalog`).
///   3. `resource_capabilities` (when a resource is supplied) — which
///      blocks are actually enabled on that specific resource.
///
/// Permission gating (e.g. "can THIS user record an expense?") is
/// orthogonal and lives in `GovernanceService` which calls the
/// `has_permission` RPC. Resolver answers "is the surface available";
/// governance answers "is this user allowed".
public extension CapabilityResolver {

    // MARK: - Resource creation gates

    /// Can this group host new resources of `type`? Considers active
    /// modules, template, and the catalog's enabledResourceTypes for any
    /// blocks the group's modules provide.
    func canCreateResource(_ type: ResourceType, in group: Group, template: Template?) -> Bool {
        supports(resourceType: type, in: group, template: template)
    }

    // MARK: - Capability gates

    /// Capability block ids the group exposes for `resourceType`. Union of
    /// every block provided by an active module that's enabled-on this
    /// resource type per the catalog.
    func availableCapabilities(
        for resourceType: ResourceType,
        in group: Group,
        catalog: CapabilityCatalog = .v1
    ) -> [String] {
        let activeModuleIds = Set(group.effectiveActiveModules)
        var ids: Set<String> = []
        for module in modules.modules where activeModuleIds.contains(module.id) {
            for blockId in module.providedCapabilityBlocks {
                guard let block = catalog[blockId] else { continue }
                if block.enabledResourceTypes.contains(resourceType) {
                    ids.insert(blockId)
                }
            }
        }
        return Array(ids).sorted()
    }

    /// Whether `blockId` is currently enabled on a specific resource via
    /// `resource_capabilities`. The caller passes the loaded
    /// `[ResourceCapability]` so the resolver stays sync.
    func isCapabilityActive(
        _ blockId: String,
        on resource: any Resource,
        capabilities: [ResourceCapability]
    ) -> Bool {
        capabilities.contains {
            $0.resourceId == resource.id
                && $0.capabilityBlockId == blockId
                && $0.enabled
        }
    }

    /// Whether a capability block COULD be enabled on this resource type
    /// (group has the providing module + block accepts the type +
    /// dependencies are also satisfied).
    func canEnableCapability(
        _ blockId: String,
        on resourceType: ResourceType,
        in group: Group,
        catalog: CapabilityCatalog = .v1
    ) -> Bool {
        let available = Set(availableCapabilities(for: resourceType, in: group, catalog: catalog))
        guard available.contains(blockId) else { return false }
        guard let block = catalog[blockId] else { return false }
        for dep in block.dependencies where !available.contains(dep) {
            return false
        }
        return true
    }

    // MARK: - Section / action gates

    /// Whether a UI section should be visible for the current group +
    /// member. Sections map to capability block routes (`CapabilityRoute`).
    /// A section is visible when ANY active module provides a block whose
    /// routes include this section id.
    func canViewSection(
        _ sectionId: String,
        in group: Group,
        catalog: CapabilityCatalog = .v1
    ) -> Bool {
        let activeModuleIds = Set(group.effectiveActiveModules)
        for module in modules.modules where activeModuleIds.contains(module.id) {
            for blockId in module.providedCapabilityBlocks {
                guard let block = catalog[blockId] else { continue }
                if block.routes.contains(where: { $0.id == sectionId }) {
                    return true
                }
            }
        }
        return false
    }

    /// All section ids the group can render right now. Drives capability-
    /// aware navigation in GroupHomeView etc.
    func availableSections(
        in group: Group,
        catalog: CapabilityCatalog = .v1
    ) -> [String] {
        let activeModuleIds = Set(group.effectiveActiveModules)
        var ids: Set<String> = []
        for module in modules.modules where activeModuleIds.contains(module.id) {
            for blockId in module.providedCapabilityBlocks {
                guard let block = catalog[blockId] else { continue }
                for route in block.routes { ids.insert(route.id) }
            }
        }
        return Array(ids).sorted()
    }

    /// Whether a given action is exposed by any active module's capability.
    /// Permission gating (can THIS user perform it) is GovernanceService's
    /// job — the resolver only confirms the action SURFACE is enabled.
    func canPerformAction(
        _ actionId: String,
        in group: Group,
        catalog: CapabilityCatalog = .v1
    ) -> Bool {
        let activeModuleIds = Set(group.effectiveActiveModules)
        for module in modules.modules where activeModuleIds.contains(module.id) {
            for blockId in module.providedCapabilityBlocks {
                guard let block = catalog[blockId] else { continue }
                if block.actions.contains(where: { $0.id == actionId }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Atomic queries (parity with Taxonomy spec §E)

    /// Whether the group can manage rules at all (rules capability block
    /// is provided by any active module).
    func canManageRule(in group: Group, catalog: CapabilityCatalog = .v1) -> Bool {
        availableCapabilities(for: .event, in: group, catalog: catalog).contains("rules")
    }

    /// Whether the group can attach guests to its resources.
    func canInviteGuest(to resourceType: ResourceType, in group: Group, catalog: CapabilityCatalog = .v1) -> Bool {
        availableCapabilities(for: resourceType, in: group, catalog: catalog).contains("guest_access")
    }

    /// Whether slot-assignment surfaces are available.
    func canAssignSlot(in group: Group, catalog: CapabilityCatalog = .v1) -> Bool {
        availableCapabilities(for: .slot, in: group, catalog: catalog).contains("assignment")
    }

    /// Whether expenses can be recorded against the given resource type.
    func canRecordExpense(on resourceType: ResourceType, in group: Group, catalog: CapabilityCatalog = .v1) -> Bool {
        availableCapabilities(for: resourceType, in: group, catalog: catalog).contains("money")
    }

    /// Whether settlement actions are available group-wide.
    func canSettleBalance(in group: Group, catalog: CapabilityCatalog = .v1) -> Bool {
        availableCapabilities(for: .event, in: group, catalog: catalog).contains("ledger")
            || availableCapabilities(for: .fund, in: group, catalog: catalog).contains("ledger")
    }

    /// Whether voting surfaces are available for the resource type.
    func canVote(on resourceType: ResourceType, in group: Group, catalog: CapabilityCatalog = .v1) -> Bool {
        availableCapabilities(for: resourceType, in: group, catalog: catalog).contains("voting")
    }
}
