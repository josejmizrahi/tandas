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

    public init(
        key: String,
        label: String,
        kind: Kind,
        placeholder: String? = nil,
        helpText: String? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.placeholder = placeholder
        self.helpText = helpText
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
    /// Optional default consequence — e.g. fine_amount=200. The wizard
    /// surfaces this as an editable field when the user selects the rule.
    public let defaultConfig: [String: String]

    public init(slug: String, displayName: String, summary: String, defaultConfig: [String: String] = [:]) {
        self.slug = slug
        self.displayName = displayName
        self.summary = summary
        self.defaultConfig = defaultConfig
    }
}
