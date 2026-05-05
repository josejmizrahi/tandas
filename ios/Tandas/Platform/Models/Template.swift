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

    public init(
        id: String,
        availableInVersion: Int,
        defaultModules: [String]? = nil,
        defaultGovernance: GovernanceRules? = nil,
        defaultSettings: JSONConfig? = nil,
        defaultRules: [TemplateRule]? = nil,
        suggestedTabs: [TabConfig]? = nil,
        onboardingFlow: [OnboardingStepConfig]? = nil
    ) {
        self.id = id
        self.availableInVersion = availableInVersion
        self.defaultModules = defaultModules
        self.defaultGovernance = defaultGovernance
        self.defaultSettings = defaultSettings
        self.defaultRules = defaultRules
        self.suggestedTabs = suggestedTabs
        self.onboardingFlow = onboardingFlow
    }
}
