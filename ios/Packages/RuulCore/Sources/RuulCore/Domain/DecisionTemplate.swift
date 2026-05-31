import Foundation

// MARK: - V3-D.18 — Decision template (governance recipe)
//
// One row from `list_decision_templates()` / `decision_templates_catalog`.
// template_key is the canonical identifier; the row carries the defaults
// the propose sheet pre-fills with. Doctrine: decision_type stays the
// topic, the template is the recipe (method/legitimacy/quorum/exec mode).

public enum DecisionExecutionMode: String, Codable, Sendable, Hashable, CaseIterable {
    case auto
    case manual
    case secondaryApproval = "secondary_approval"
}

public struct DecisionTemplate: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let templateKey: String
    public let displayName: String
    public let description: String?
    public let decisionType: String
    public let referenceKind: String?
    public let defaultMethod: String
    public let defaultLegitimacySource: String
    public let defaultThresholdPct: Decimal?
    public let defaultQuorumPct: Decimal?
    public let executionMode: DecisionExecutionMode
    public let metadata: [String: RPCJSONValue]?

    public var id: String { templateKey }

    enum CodingKeys: String, CodingKey {
        case templateKey             = "template_key"
        case displayName             = "display_name"
        case description
        case decisionType            = "decision_type"
        case referenceKind           = "reference_kind"
        case defaultMethod           = "default_method"
        case defaultLegitimacySource = "default_legitimacy_source"
        case defaultThresholdPct     = "default_threshold_pct"
        case defaultQuorumPct        = "default_quorum_pct"
        case executionMode           = "execution_mode"
        case metadata
    }

    public init(
        templateKey: String,
        displayName: String,
        description: String? = nil,
        decisionType: String,
        referenceKind: String? = nil,
        defaultMethod: String,
        defaultLegitimacySource: String,
        defaultThresholdPct: Decimal? = nil,
        defaultQuorumPct: Decimal? = nil,
        executionMode: DecisionExecutionMode = .manual,
        metadata: [String: RPCJSONValue]? = nil
    ) {
        self.templateKey = templateKey
        self.displayName = displayName
        self.description = description
        self.decisionType = decisionType
        self.referenceKind = referenceKind
        self.defaultMethod = defaultMethod
        self.defaultLegitimacySource = defaultLegitimacySource
        self.defaultThresholdPct = defaultThresholdPct
        self.defaultQuorumPct = defaultQuorumPct
        self.executionMode = executionMode
        self.metadata = metadata
    }
}

// MARK: - V3-D.18 — execute_decision return

public struct ExecuteDecisionResult: Codable, Sendable, Hashable, Equatable {
    public let decisionId: UUID
    public let status: String
    public let outcome: String?
    public let effects: [String: RPCJSONValue]?

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case status, outcome, effects
    }

    public init(decisionId: UUID, status: String, outcome: String? = nil, effects: [String: RPCJSONValue]? = nil) {
        self.decisionId = decisionId
        self.status = status
        self.outcome = outcome
        self.effects = effects
    }
}
