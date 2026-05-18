import Foundation

/// Per-instance availability filter used by the toolbar `+` to hide
/// intents that would fail server-side given the resource's current
/// state. Layered on top of the post-create filters (type + caps +
/// permissions) so the toolbar surface stays honest:
///
///   - Don't show "Liberar custodia" when there's no custodian
///   - Don't show "Marcar devuelto" when nothing's checked out
///   - Don't show "Bloquear fondo" when already locked
///   - etc.
///
/// The runtime gate consults `intent.id` to look up its per-id rule.
/// Unknown ids pass through (`true`) so adding an intent doesn't break
/// the gate — the per-id rule is added explicitly when the intent
/// needs one.
public enum ResourceIntentRuntimeGate {
    /// Returns true when the intent should appear in the toolbar for
    /// this resource + viewer right now. Composes three layers:
    ///
    ///   1. `resourceTypes` includes the resource's type.
    ///   2. `permissionsRequired` ⊆ viewerPermissions.
    ///   3. `requiredCapabilities` ⊆ enabledCapabilities. (Toolbar mode:
    ///      caps must already be on. Post-create uses a different gate
    ///      that allows missing-but-attachable caps.)
    ///   4. Per-id state rule. Hidden if the rule says no.
    public static func isAvailable(
        _ intent: ResourceIntent,
        in ctx: ResourceIntentContext
    ) -> Bool {
        guard intent.resourceTypes.contains(ctx.resource.resourceType) else {
            return false
        }
        for perm in intent.permissionsRequired {
            if !ctx.viewerPermissions.contains(perm) { return false }
        }
        if !intent.requiredCapabilities.isSubset(of: ctx.enabledCapabilities) {
            return false
        }
        return matchesState(intent: intent, in: ctx)
    }

    // MARK: - Per-id state rules

    private static func matchesState(
        intent: ResourceIntent,
        in ctx: ResourceIntentContext
    ) -> Bool {
        let m = ctx.resource.metadata
        let hasCustodian = isNonEmpty(m["custodian_id"]?.stringValue)
        let hasHolder    = isNonEmpty(m["checked_out_to"]?.stringValue)
        let hasOwner     = isNonEmpty(m["owner_id"]?.stringValue)
        let isLocked     = isNonEmpty(m["locked_at"]?.stringValue)
        let isArchived   = ctx.resource.status == "archived"

        // Archived resources hide every action except (eventually) restore.
        // Phase 1 has no restore intent — toolbar collapses entirely for
        // archived resources, which is fine: the user reads the resource,
        // they don't act on it.
        if isArchived { return false }

        switch intent.id {
        // --- Asset custody ---
        case "assign_custody":
            // Can't reassign while checked out (data integrity per mig 00200).
            return !hasHolder
        case "release_custody":
            return hasCustodian && !hasHolder
        case "checkout_asset":
            // Existing behavior in AssetCustodySection: a custodian must be
            // assigned before the asset can be lent out. Mirror it here.
            return hasCustodian && !hasHolder
        case "mark_returned_asset":
            return hasHolder

        // --- Asset ownership ---
        case "transfer_asset":
            return true  // perm gate above already requires admin
        case "return_asset_to_group":
            return hasOwner

        // --- Fund lifecycle ---
        case "lock_fund":
            return !isLocked
        case "unlock_fund":
            return isLocked

        // --- No state rule (always show when type/perm/caps pass) ---
        default:
            return true
        }
    }

    private static func isNonEmpty(_ s: String?) -> Bool {
        guard let s else { return false }
        return !s.isEmpty
    }
}
