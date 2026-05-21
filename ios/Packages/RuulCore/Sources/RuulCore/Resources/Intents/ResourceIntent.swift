import Foundation

/// User-facing "what do you want to do now?" verb attached to a Resource.
///
/// Doctrine: `ResourceIntent` is THE canonical model of "things you can do
/// with a Resource." It serves multiple surfaces from one Registry:
///
///   - Post-create screen  — after creating, "what next?" picker
///   - Resource detail `+` — toolbar action menu
///   - Empty-state CTAs    — "Aún sin movimientos. ¿Registrar uno?"
///   - Future AI suggestions
///
/// The conceptual split that keeps this honest:
///
///   `ResourceIntent` = intención humana   (what the user wants)
///   `Destination`    = cómo se ejecuta    (which sheet / form / RPC)
///   `Capability`     = infraestructura    (what backend the destination needs)
///
/// Capabilities are infrastructure and stay HIDDEN from the user.
/// `LazyCapabilityActivator` brings missing caps online when an intent
/// is tapped (post-create path); the toolbar path requires caps already
/// be enabled (it filters intents whose `requiredCapabilities` aren't
/// in `enabledCapabilities`).
///
/// Hidden vs greyed: an intent that's gated out (caps not available,
/// permission missing, resource state forbids it) is HIDDEN, never
/// greyed. Greying invites the "why?" question that exposes governance
/// plumbing.
public struct ResourceIntent: Sendable, Hashable, Identifiable {
    /// Stable id. Snake_case verbs: "track_money", "invite_people",
    /// "allow_reservations".
    public let id: String

    /// What the button says. Founder voice, no doctrine terms. Per
    /// 2026-05-18 adjustment: "ledger" is forbidden in user copy even
    /// though `Destination.ledgerEntryForm` is fine as an internal id.
    public let humanLabel: String

    /// One-line description shown under the label. Tells the user what
    /// happens when they tap.
    public let summary: String

    /// SF Symbol.
    public let icon: String

    /// Resource types this intent applies to. Surfaces filter by
    /// `resourceTypes.contains(resource.resourceType)`.
    public let resourceTypes: Set<ResourceType>

    /// Capability ids the intent needs. Post-create:
    /// `LazyCapabilityActivator.ensure` attaches missing-but-stable
    /// ones silently. Toolbar: filter requires they're already enabled.
    public let requiredCapabilities: Set<String>

    /// Whether to silently attach + push the destination, or show a
    /// primer sheet first so the user can confirm. Only consulted by
    /// the post-create path; the toolbar always dispatches directly.
    public let activation: ActivationStrategy

    /// Where the dispatcher routes after activation succeeds.
    public let destination: Destination

    /// Permissions the user must hold. Resolved via `GovernanceService`
    /// / `has_permission`. Intent is hidden if any permission is
    /// missing — never greyed.
    public let permissionsRequired: [Permission]

    /// Copy shown on the destination screen when there is no data yet
    /// (e.g. "Sé el primero en registrar un gasto.").
    public let firstRunCopy: String

    /// Empty-state copy shown by surfaces this intent owns when there
    /// is no data of its kind anywhere. Distinct from `firstRunCopy`
    /// (first-tap copy on the destination form).
    public let emptyStateCopy: String

    /// Sectioning group for the toolbar `+` menu. The post-create
    /// screen ignores this (one flat list). Defaults to `.actions`
    /// for backward compat with intents written before grouping
    /// existed.
    public let group: IntentGroup

    /// Renders the menu item with `.destructive` role (red label, iOS
    /// confirmation prompt for some destinations). Only consulted by
    /// the toolbar surface; the post-create screen doesn't distinguish.
    public let isDestructive: Bool

    /// Whether this intent belongs in the ⚙️ Ajustes menu of the
    /// resource detail rather than the + Acciones menu. Today this is
    /// reserved for `edit_details` + `archive_resource` — configuration
    /// of the resource itself, not actions on it. Per doctrine 2026-05-
    /// 18: ⚙️ stays minimal; if you're tempted to add a third entry,
    /// it probably belongs in an "Avanzado" sub-sheet instead.
    public let isResourceSetting: Bool

    public init(
        id: String,
        humanLabel: String,
        summary: String,
        icon: String,
        resourceTypes: Set<ResourceType>,
        requiredCapabilities: Set<String> = [],
        activation: ActivationStrategy = .silent,
        destination: Destination,
        permissionsRequired: [Permission] = [],
        firstRunCopy: String = "",
        emptyStateCopy: String = "",
        group: IntentGroup = .actions,
        isDestructive: Bool = false,
        isResourceSetting: Bool = false
    ) {
        self.id = id
        self.humanLabel = humanLabel
        self.summary = summary
        self.icon = icon
        self.resourceTypes = resourceTypes
        self.requiredCapabilities = requiredCapabilities
        self.activation = activation
        self.destination = destination
        self.permissionsRequired = permissionsRequired
        self.firstRunCopy = firstRunCopy
        self.emptyStateCopy = emptyStateCopy
        self.group = group
        self.isDestructive = isDestructive
        self.isResourceSetting = isResourceSetting
    }
}

/// Sectioning for the toolbar `+` menu. Each intent declares its group;
/// the menu renders one `Section(group.label) { ... }` per non-empty
/// group, ordered by `sortOrder`. Per founder doctrine 2026-05-18:
/// "Por intención humana. No por capabilities."
public enum IntentGroup: String, CaseIterable, Sendable, Hashable {
    /// Lifecycle / direct manipulation. "Hacer cosas con el recurso."
    case actions
    /// Monetary verbs (aportar, gasto, valuación, ver movimientos).
    case money
    /// Cross-resource verbs (compartir, vincular).
    case coordination
    /// Configuration-ish verbs that still belong in `+` because they're
    /// user-facing actions, not resource settings. Rare today.
    case governance
    /// History / audit. Today HISTORIAL lives as a tab so the + rarely
    /// needs to expose it; reserved for future use.
    case history

    /// Spanish header shown above the section in the menu.
    public var label: String {
        switch self {
        case .actions:      return "Acciones"
        case .money:        return "Dinero"
        case .coordination: return "Coordinación"
        case .governance:   return "Gobierno"
        case .history:      return "Historial"
        }
    }

    /// Section ordering within the menu (lower = higher).
    public var sortOrder: Int {
        switch self {
        case .actions:      return 0
        case .money:        return 1
        case .coordination: return 2
        case .governance:   return 3
        case .history:      return 4
        }
    }
}

/// How `LazyCapabilityActivator` brings the required caps online for
/// an intent.
public enum ActivationStrategy: Sendable, Hashable {
    /// Attach caps and push destination immediately. Default for verbs
    /// the user clearly meant ("Registrar gasto" — obvious intent).
    case silent

    /// Show a primer sheet first explaining what's about to happen and
    /// letting the user back out. Use for verbs that change group-wide
    /// behavior or surface new sections to other members
    /// ("Permitir reservas" — adds a booking surface everyone sees).
    case primerSheet(title: String, body: String, ctaLabel: String)
}

/// Where the dispatcher sends the user after a successful activation.
/// Internal ids — never shown to the user. Per 2026-05-18 adjustment 2,
/// `ledgerEntryForm` is allowed as an internal id even though "ledger"
/// is banned from user copy.
///
/// Two flavors live here together:
///
///   1. Navigation destinations — used by the post-create dispatcher
///      to push the user into a form / tab / wizard.
///   2. Action-sheet destinations — used by the resource detail toolbar
///      `+` to present a sheet bound to the current resource.
///
/// They share one enum because the same `ResourceIntent` powers both
/// surfaces; the consumer decides how to dispatch each case.
public enum Destination: Sendable, Hashable {
    // --- Navigation (post-create, also reusable from toolbar) ---
    case ledgerEntryForm(prefill: LedgerPrefill?)
    case reservationSetup
    case rightCreationFlow
    case ruleTemplatePicker(category: RuleCategoryFilter?)
    case linkPicker(kindHint: String?)
    case custodyAssignment
    case valuationForm
    case rsvpManager
    case checkInLauncher
    case slotAllocationForm
    case rightHolderForm
    case governanceRuleEditor
    case historyTab
    case moneyTab
    case childResourceWizard(prefilledType: ResourceType?)

    // --- Action sheets (toolbar `+`, direct mutations on the current
    // resource — these do NOT navigate, they present a sheet bound to
    // the resource and call its RPC on submit). ---

    /// Picker → `transfer_asset` RPC (mig 00210). Reuses
    /// `MemberPickerSheet`.
    case transferAssetPicker

    /// Confirmation → `transfer_asset(to: nil)` (return ownership
    /// to the group, no sheet — direct RPC with confirm).
    case returnAssetToGroupConfirm

    /// Confirmation → `release_custody` (no sheet, direct RPC).
    case releaseCustodyConfirm

    /// Picker → `assign_custody`. Distinct from `custodyAssignment`
    /// (navigation) — this one stays inline on the detail.
    case assignCustodyPicker

    /// Sheet → `CheckOutAssetSheet` → `checkout_asset` RPC.
    case checkoutAssetSheet

    /// Confirmation → `checkin_asset` (mark returned). No sheet.
    case markReturnedConfirm

    /// Sheet → `RecordValuationSheet`. Distinct from `.valuationForm`
    /// which the post-create path uses for navigation.
    case recordValuationSheet

    /// Sheet → `LogMaintenanceSheet`.
    case logMaintenanceSheet

    /// Sheet → `ReportDamageSheet`.
    case reportDamageSheet

    /// Sheet → `CreateSlotSheet` (slot child under this asset).
    case createSlotUnderAssetSheet

    /// Sheet → `ContributeToFundSheet` → `fund_contribute` RPC.
    case fundContributeSheet

    /// Sheet → `RecordExpenseFromFundSheet` → `fund_record_expense` RPC.
    case fundRecordExpenseSheet

    /// Sheet → `LockFundSheet` → `fund_lock` RPC (sheet collects reason).
    case fundLockSheet

    /// Confirmation → `fund_unlock` RPC. No sheet.
    case fundUnlockConfirm

    /// System share sheet (UIActivityViewController) with a resource
    /// deep link.
    case systemShareSheet

    /// Per-type edit sheet (e.g. `EditRightSheet` for rights). The
    /// dispatcher picks the matching sheet by `resource.resourceType`.
    case editResourceSheet

    /// Confirmation → `archive_resource` RPC (mig 00291).
    case archiveResourceConfirm

    public enum LedgerPrefill: Sendable, Hashable {
        case credit  // aportación
        case debit   // gasto
    }

    public enum RuleCategoryFilter: Sendable, Hashable {
        case priority
        case approval
        case access
        case money
        case obligation
    }
}
