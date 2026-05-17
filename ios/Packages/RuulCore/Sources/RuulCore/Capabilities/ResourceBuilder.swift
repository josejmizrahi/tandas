import Foundation

/// Unified entry point for creating any resource type per OpenPlatform
/// Taxonomy §B (ResourceBuilder design).
///
/// One builder per resource type. Each builder declares its required
/// fields (simple-mode minimum) and accepts a list of optional
/// capabilities the user opted into through the wizard.
///
/// The builder orchestrates:
///   1. Persist the core resource row (delegates to the type-specific
///      RPC, e.g. `create_event_v2` for events).
///   2. If draft.seriesPattern is set, create or attach a ResourceSeries.
///   3. For each enabled capability, persist its config to
///      `resource_capabilities`.
///   4. For each rule draft, seed it via the rules pipeline.
///   5. Return a ResourceCreationResult summarising what was created.
public protocol ResourceBuilder: Sendable {
    /// What resource_type this builder produces.
    var resourceType: ResourceType { get }

    /// User-facing label shown in the type picker.
    var displayName: String { get }

    /// SF Symbol id rendered on the type picker card.
    var icon: String { get }

    /// One-line description shown below the title on the picker card.
    var summary: String { get }

    /// Required fields the wizard renders in step 2 (cannot be skipped).
    var requiredFields: [BuilderField] { get }

    /// Optional capability blocks the wizard surfaces in step 3.
    var optionalCapabilities: [String] { get }

    func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult
}

/// Payload describing the resource the user wants to create. Wizard fills
/// this progressively; the builder consumes it.
public struct ResourceDraft: Sendable {
    public let groupId: UUID
    public let resourceType: ResourceType

    /// Required + filled-in optional builder field values. Keys are
    /// `BuilderField.key`. Values are typed via JSONConfig so the
    /// builder can re-encode for the RPC payload.
    public let basicFields: [String: JSONConfig]

    /// Capability block ids the user opted into during the wizard.
    /// Builder is responsible for honoring transitive dependencies
    /// (lookup via `CapabilityCatalog.transitiveDependencies(of:)`).
    public let enabledCapabilities: [String]

    /// Per-capability config supplied by the user. Keyed by capability
    /// block id. Maps to `resource_capabilities.config` jsonb on insert.
    public let capabilityConfigs: [String: JSONConfig]

    /// Optional series pattern. When non-nil, the builder creates a
    /// ResourceSeries first and attaches the resource as occurrence #1.
    public let seriesPattern: JSONConfig?

    /// Rules the user wants seeded along with the resource. Builder
    /// creates each via the rules pipeline scoped to the resource (or
    /// its series, if any).
    public let initialRules: [RuleDraft]

    public init(
        groupId: UUID,
        resourceType: ResourceType,
        basicFields: [String: JSONConfig] = [:],
        enabledCapabilities: [String] = [],
        capabilityConfigs: [String: JSONConfig] = [:],
        seriesPattern: JSONConfig? = nil,
        initialRules: [RuleDraft] = []
    ) {
        self.groupId = groupId
        self.resourceType = resourceType
        self.basicFields = basicFields
        self.enabledCapabilities = enabledCapabilities
        self.capabilityConfigs = capabilityConfigs
        self.seriesPattern = seriesPattern
        self.initialRules = initialRules
    }

    /// Returns a copy of this draft with Tier 0 + Tier 0.5 capability
    /// defaults merged into `enabledCapabilities`. Builders call this
    /// before persisting so every new resource ships with the universals
    /// (status/description/history/rules/voting) and — when the type is
    /// eligible — the economic Tier 0.5 (ledger/money). See
    /// `Plans/Active/CapabilityTiers.md` for the canonical contract.
    public func withTierDefaults() -> ResourceDraft {
        let merged = CapabilityCatalog.mergeTierDefaults(
            explicit: enabledCapabilities,
            for: resourceType
        )
        if merged.elementsEqual(enabledCapabilities) { return self }
        return ResourceDraft(
            groupId: groupId,
            resourceType: resourceType,
            basicFields: basicFields,
            enabledCapabilities: merged,
            capabilityConfigs: capabilityConfigs,
            seriesPattern: seriesPattern,
            initialRules: initialRules
        )
    }
}

/// What the builder produced. Coordinator can use this to navigate to
/// the new resource, refresh state, or trigger downstream UI.
public struct ResourceCreationResult: Sendable {
    public let resourceId: UUID
    public let seriesId: UUID?
    public let enabledCapabilityIds: [String]
    public let createdRuleIds: [UUID]
    public let cascadedModuleIds: [String]

    public init(
        resourceId: UUID,
        seriesId: UUID? = nil,
        enabledCapabilityIds: [String] = [],
        createdRuleIds: [UUID] = [],
        cascadedModuleIds: [String] = []
    ) {
        self.resourceId = resourceId
        self.seriesId = seriesId
        self.enabledCapabilityIds = enabledCapabilityIds
        self.createdRuleIds = createdRuleIds
        self.cascadedModuleIds = cascadedModuleIds
    }
}

/// Errors a builder may surface to the wizard.
public enum ResourceBuilderError: Error, Equatable {
    case missingRequiredField(String)
    case unsupportedCapability(String)
    case capabilityConflict(String, String)
    case rpcFailed(String)
    case underlying(String)
}
