import Foundation

/// A serializable template definition. Persisted in `public.templates`.
/// The Swift `TemplateRegistry` (Bloque 5) reads these at boot and uses
/// them to drive group creation, tab rendering, and onboarding flow.
///
/// V1 ships one available template (`recurring_dinner`) plus three
/// placeholder rows (`shared_resource`, `rotating_savings`, `custom`)
/// that show in the selector but cannot be picked.
public struct Template: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let version: Int
    public let name: String
    public let description: String
    public let icon: String              // SF Symbol name
    public let config: TemplateConfig
    public let available: Bool
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, icon, config, available
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // MARK: - Effective presentation accessors

    /// Display name shown in onboarding/info — prefers
    /// `config.presentation.displayName`, falls back to `Template.name`.
    /// Audit doc § 5.3 item 7c — Template absorbs presentation from the
    /// legacy GroupType enum.
    public var effectiveDisplayName: String {
        config.presentation?.displayName ?? name
    }

    /// SF Symbol — prefers `config.presentation.symbolName`, falls back
    /// to `Template.icon`.
    public var effectiveSymbolName: String {
        config.presentation?.symbolName ?? icon
    }

    /// Long copy — prefers `config.presentation.description`, falls back
    /// to `Template.description`.
    public var effectiveDescription: String {
        config.presentation?.description ?? description
    }

    /// Bulleted highlights. May be empty if `config.presentation` doesn't
    /// declare any.
    public var effectiveBullets: [String] {
        config.presentation?.bullets ?? []
    }

    /// Default per-event vocabulary. Prefers
    /// `config.presentation.defaultEventLabel`, then
    /// `config.defaultSettings.eventVocabulary`, then `"evento"` as a
    /// last-ditch sensible default.
    public var effectiveDefaultEventLabel: String {
        if let p = config.presentation?.defaultEventLabel { return p }
        if case let .object(dict) = config.defaultSettings,
           let label = dict["eventVocabulary"]?.stringValue {
            return label
        }
        return "evento"
    }

    /// Default `GroupCategory` for groups created from this template.
    /// Falls back to `.socialRecurring` (matches the DB default).
    public var effectiveDefaultCategory: GroupCategory {
        config.defaultCategory ?? .socialRecurring
    }
}

/// The body of a `Template`. Mirrors the `templates.config` jsonb keys.
/// All inner fields are optional so placeholder templates (which only set
/// `id` + `availableInVersion`) decode without errors.
public struct TemplateConfig: Sendable, Codable, Hashable {
    public let id: String
    public let availableInVersion: Int
    public let defaultModules: [String]?
    public let defaultGovernance: GovernanceRules?
    public let defaultSettings: JSONConfig?
    public let defaultRules: [TemplateRule]?
    public let suggestedTabs: [TabConfig]?
    public let onboardingFlow: [OnboardingStepConfig]?

    /// Resource types this template instantiates. V1 always `[.event]`
    /// for backward compat. Phase 2+ templates (shared_resource,
    /// rotating_savings) declare their own types. Optional so configs
    /// seeded pre-Sub-fase E decode without errors — use
    /// `effectiveResourceTypes` to read with the default fallback.
    public let resourceTypes: [ResourceType]?

    /// User-facing presentation metadata (display name, symbol, copy,
    /// bullets, default event label). Audit doc § 5.3 item 7c — folds
    /// the legacy `GroupType` enum data into the template config.
    /// Optional so configs seeded pre-migration 00037 decode without
    /// errors — read via `Template.effective*` accessors.
    public let presentation: TemplatePresentation?

    /// Default `GroupCategory` for groups created from this template.
    /// Drives the avatar color ramp and segmentation. Optional so
    /// configs seeded pre-migration 00037 decode without errors —
    /// callers should use `Template.effectiveDefaultCategory`.
    public let defaultCategory: GroupCategory?

    /// Effective resource types — defaults to `[.event]` if config
    /// doesn't declare them (backward compat for templates seeded
    /// pre-Sub-fase E).
    public var effectiveResourceTypes: [ResourceType] {
        resourceTypes ?? [.event]
    }

    public init(
        id: String,
        availableInVersion: Int,
        defaultModules: [String]? = nil,
        defaultGovernance: GovernanceRules? = nil,
        defaultSettings: JSONConfig? = nil,
        defaultRules: [TemplateRule]? = nil,
        suggestedTabs: [TabConfig]? = nil,
        onboardingFlow: [OnboardingStepConfig]? = nil,
        resourceTypes: [ResourceType]? = nil,
        presentation: TemplatePresentation? = nil,
        defaultCategory: GroupCategory? = nil
    ) {
        self.id = id
        self.availableInVersion = availableInVersion
        self.defaultModules = defaultModules
        self.defaultGovernance = defaultGovernance
        self.defaultSettings = defaultSettings
        self.defaultRules = defaultRules
        self.suggestedTabs = suggestedTabs
        self.onboardingFlow = onboardingFlow
        self.resourceTypes = resourceTypes
        self.presentation = presentation
        self.defaultCategory = defaultCategory
    }
}
