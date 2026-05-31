import Foundation

// MARK: - V3-D.18 — Decision provenance
//
// Mirrors `decision_provenance(p_decision_id)` jsonb payload. Answers
// "¿Por qué existe esta decisión?" Source can be:
//   * `manual` — created via UI / API by a user
//   * `rule`   — created by `consequence.start_vote` from a rule
// When source=rule, the rule title, consequence kind and originating
// event are populated.

public enum DecisionSourceType: String, Codable, Sendable, Hashable {
    case manual
    case rule
    case unknown
}

public struct DecisionProvenance: Codable, Sendable, Hashable, Equatable {
    public let found: Bool
    public let reason: String?
    public let decisionId: UUID?
    public let sourceType: DecisionSourceType?
    public let sourceEventId: UUID?
    public let sourceRuleTitle: String?
    public let sourceConsequenceKind: String?
    public let sourceEntityKind: String?
    public let sourceEntityId: UUID?
    public let evaluationId: UUID?
    public let matchedPredicate: RulePredicateOutcome?
    public let depth: Int?
    public let createdAt: Date?
    public let createdBy: UUID?
    public let templateKey: String?
    public let sourceEvent: ProvenanceSourceEvent?

    enum CodingKeys: String, CodingKey {
        case found, reason
        case decisionId             = "decision_id"
        case sourceType             = "source_type"
        case sourceEventId          = "source_event_id"
        case sourceRuleTitle        = "source_rule_title"
        case sourceConsequenceKind  = "source_consequence_kind"
        case sourceEntityKind       = "source_entity_kind"
        case sourceEntityId         = "source_entity_id"
        case evaluationId           = "evaluation_id"
        case matchedPredicate       = "matched_predicate"
        case depth
        case createdAt              = "created_at"
        case createdBy              = "created_by"
        case templateKey            = "template_key"
        case sourceEvent            = "source_event"
    }

    public init(
        found: Bool,
        reason: String? = nil,
        decisionId: UUID? = nil,
        sourceType: DecisionSourceType? = nil,
        sourceEventId: UUID? = nil,
        sourceRuleTitle: String? = nil,
        sourceConsequenceKind: String? = nil,
        sourceEntityKind: String? = nil,
        sourceEntityId: UUID? = nil,
        evaluationId: UUID? = nil,
        matchedPredicate: RulePredicateOutcome? = nil,
        depth: Int? = nil,
        createdAt: Date? = nil,
        createdBy: UUID? = nil,
        templateKey: String? = nil,
        sourceEvent: ProvenanceSourceEvent? = nil
    ) {
        self.found = found
        self.reason = reason
        self.decisionId = decisionId
        self.sourceType = sourceType
        self.sourceEventId = sourceEventId
        self.sourceRuleTitle = sourceRuleTitle
        self.sourceConsequenceKind = sourceConsequenceKind
        self.sourceEntityKind = sourceEntityKind
        self.sourceEntityId = sourceEntityId
        self.evaluationId = evaluationId
        self.matchedPredicate = matchedPredicate
        self.depth = depth
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.templateKey = templateKey
        self.sourceEvent = sourceEvent
    }
}
