import Foundation

/// A composable capability that can be attached to a Resource per the
/// OpenPlatform Taxonomy §2.
///
/// A `CapabilityBlock` declares its contract: which resource types accept
/// it, what config it needs, what actions/routes/permissions it exposes,
/// what projections it produces, and how it relates to other blocks via
/// dependencies and conflicts.
///
/// Modules provide capability blocks (`modules.provided_capability_blocks`,
/// mig 00078). When a module is in `groups.active_modules`, every block
/// it provides becomes available for resources in that group.
///
/// Catalog lives in code (`CapabilityCatalog`) for now. Phase 2+ may
/// promote to a `public.capability_blocks` table if the registry needs
/// to evolve without redeploys.
public protocol CapabilityBlock: Sendable {
    /// Stable, unique id matching the `capability_block_id` strings on the
    /// server (modules.provided_capability_blocks, resource_capabilities).
    var id: String { get }

    /// Display name shown in wizards / settings UI.
    var displayName: String { get }

    /// One-line description for hover text / wizard subtitle.
    var summary: String { get }

    /// Resource types that can have this capability attached.
    var enabledResourceTypes: [ResourceType] { get }

    /// Required config fields. Wizard renders these with no skip option.
    var requiredFields: [BuilderField] { get }

    /// Optional config fields. Wizard hides these behind "Add more options".
    var optionalFields: [BuilderField] { get }

    /// Suggested rules the user can pick from when configuring this block.
    /// Empty when the capability doesn't bundle rules (e.g. recurrence).
    var suggestedRules: [RuleTemplate] { get }

    /// Actions this capability exposes for the user (e.g. money → "registrar gasto").
    var actions: [CapabilityAction] { get }

    /// UI routes / sections this capability surfaces in the resource detail.
    var routes: [CapabilityRoute] { get }

    /// Permission ids this capability checks. Resolver consults
    /// `has_permission` for each.
    var permissions: [Permission] { get }

    /// Projections this capability produces (balance, attendance summary,
    /// reputation score, etc.). Drives history/analytics surfaces.
    var projections: [ProjectionDescriptor] { get }

    /// Other capability block ids this one depends on. The wizard pulls
    /// these in transitively when the user enables this block.
    var dependencies: [String] { get }

    /// Capability block ids this one conflicts with (cannot be enabled
    /// simultaneously on the same resource).
    var conflicts: [String] { get }

    /// Tier-0 truth gate: declares whether the four contract conditions
    /// are met for this block to appear in Create Resource:
    ///   1. config UI renderable (no options-less pickers, no memberPicker
    ///      fallback to free text);
    ///   2. backend save path (resource_capabilities row writeable for the
    ///      target resource type);
    ///   3. runtime support (an edge fn/RPC/cron actually consumes the
    ///      saved config or its column-shaped proxy);
    ///   4. wired through end-to-end with at least one test path.
    ///
    /// Defaults to `.stable`. Blocks that fail any of the four declare
    /// `.incomplete(reason:)` explicitly. The wizard hides incomplete
    /// blocks from step 3 and from template auto-on defaults so the user
    /// never sees a misleading toggle.
    ///
    /// Founder framing 2026-05-12: "No toggles decorativos." If a
    /// capability is half-built, surfacing it as togglable promises
    /// behavior the runtime can't deliver. Mark it incomplete; ship it
    /// when the four conditions are real.
    var status: CapabilityStatus { get }
}

/// Default `status = .stable` so existing blocks keep their behavior.
/// Blocks that are half-built override this explicitly with
/// `.incomplete(reason: …)` — the explicit string is the contract for
/// why the audit flagged it.
public extension CapabilityBlock {
    var status: CapabilityStatus { .stable }
}

/// Whether a `CapabilityBlock` is ready to surface in Create Resource.
///
/// `.stable` blocks render normally in step 3. `.incomplete` blocks are
/// hidden by the wizard until they ship config UI, save path, and
/// runtime support. The reason string is shown in catalog-debug surfaces
/// only — end users never see it; they just never see the toggle.
public enum CapabilityStatus: Sendable, Hashable {
    case stable
    case incomplete(reason: String)

    public var isStable: Bool {
        if case .stable = self { return true }
        return false
    }

    public var reason: String? {
        if case .incomplete(let r) = self { return r }
        return nil
    }
}

// MARK: - Supporting types

/// A single field the user fills when configuring a capability or
/// creating a resource.
public struct BuilderField: Sendable, Hashable {
    public let key: String
    public let label: String
    public let kind: Kind
    public let placeholder: String?
    public let helpText: String?
    /// Options for `.picker` / `.multiPicker` kinds. Each option stores
    /// the raw `JSONConfig` value that the renderer writes to the
    /// shared `values` dictionary, plus a human-readable label.
    /// Founder framing 2026-05-11: capability sub-config (recurrence,
    /// rotation, …) is declarative — define options here, not as a
    /// view-side Picker hardcoded per capability id.
    public let options: [PickerOption]?

    public enum Kind: String, Sendable, Hashable {
        case text
        case multilineText
        case integer
        case decimal
        case currency
        case boolean
        case date
        case time
        case dateTime
        case duration
        case picker      // single-choice from a fixed list
        case multiPicker // multi-choice from a fixed list
        case memberPicker
        case resourcePicker
        case money       // {amount_cents, currency}
    }

    /// A single choice in a `.picker` / `.multiPicker` field.
    public struct PickerOption: Sendable, Hashable {
        public let value: JSONConfig
        public let label: String

        public init(value: JSONConfig, label: String) {
            self.value = value
            self.label = label
        }
    }

    public init(
        key: String,
        label: String,
        kind: Kind,
        placeholder: String? = nil,
        helpText: String? = nil,
        options: [PickerOption]? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.placeholder = placeholder
        self.helpText = helpText
        self.options = options
    }
}

/// A user-facing action exposed by a capability (button, menu item).
public struct CapabilityAction: Sendable, Hashable {
    public let id: String
    public let label: String
    public let permission: Permission?
    public let surface: Surface

    public enum Surface: String, Sendable, Hashable {
        case resourceDetail
        case homeTab
        case moneyTab
        case settingsSheet
        case contextMenu
    }

    public init(id: String, label: String, permission: Permission? = nil, surface: Surface) {
        self.id = id
        self.label = label
        self.permission = permission
        self.surface = surface
    }
}

/// A UI route this capability adds to the resource detail screen.
public struct CapabilityRoute: Sendable, Hashable {
    public let id: String
    public let label: String
    public let icon: String

    public init(id: String, label: String, icon: String) {
        self.id = id
        self.label = label
        self.icon = icon
    }
}

/// A projection this capability produces. Drives derived UI sections.
public struct ProjectionDescriptor: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let scope: Scope

    public enum Scope: String, Sendable, Hashable {
        case group
        case resource
        case member
        case occurrence
    }

    public init(id: String, displayName: String, scope: Scope) {
        self.id = id
        self.displayName = displayName
        self.scope = scope
    }
}

/// A pre-fab rule the user can pick from when configuring a capability
/// block. The wizard renders these as toggleable options. Picking one
/// creates a rule row scoped to the resource (or its series/module).
public struct RuleTemplate: Sendable, Hashable {
    public let slug: String
    public let displayName: String
    public let summary: String
    /// Server-shaped trigger this template fires on. Founder framing
    /// 2026-05-11: never infer from slug — declare explicitly so adding
    /// a new template is one entry, not two coupled edits.
    public let triggerEventType: SystemEventType
    /// Consequence the rule emits when the trigger + conditions match.
    /// V1: every template ships exactly one consequence; richer
    /// envelopes arrive when the catalog needs them.
    public let consequenceType: ConsequenceType
    /// Optional default consequence config — e.g. `amount: "200"`.
    /// Flows into the consequence's jsonb when the user keeps the
    /// rule on. Also carries trigger-config keys like `hours: "24"`
    /// for an "hours-before" template.
    public let defaultConfig: [String: String]
    /// Whether the wizard pre-ticks this rule when the user enables
    /// the parent capability. Reminder/approval/social-norm templates
    /// default to `true`; monetary fines default to `false` so the
    /// user explicitly opts in. Founder framing 2026-05-11.
    public let defaultEnabled: Bool

    public init(
        slug: String,
        displayName: String,
        summary: String,
        triggerEventType: SystemEventType,
        consequenceType: ConsequenceType = .fine,
        defaultConfig: [String: String] = [:],
        defaultEnabled: Bool = true
    ) {
        self.slug = slug
        self.displayName = displayName
        self.summary = summary
        self.triggerEventType = triggerEventType
        self.consequenceType = consequenceType
        self.defaultConfig = defaultConfig
        self.defaultEnabled = defaultEnabled
    }
}
