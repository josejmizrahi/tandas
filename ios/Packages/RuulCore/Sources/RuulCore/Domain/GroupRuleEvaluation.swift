import Foundation

// MARK: - Rule evaluation audit (V2-G3.5)
//
// One row in `public.group_rule_evaluations`, hydrated via the
// `group_rule_evaluations(p_group_id, p_limit, p_before)` RPC. Carries
// enough explainability (matched_predicate.outcome + actions_emitted
// per-action detail) for iOS to render a "Disparos" feed without a
// second hop.

public struct RulePredicateOutcome: Codable, Sendable, Hashable, Equatable {
    public let passed: Bool
    public let reason: String?
    public let kind: String?
    /// Engine-specific debugging payload (e.g. `{event_amount, threshold}`
    /// for amount_above, `{actor_roles}` for actor_role_in). Always
    /// decoded as RPCJSONValue so new predicates ship without iOS edits.
    public let evaluatedValue: RPCJSONValue?

    enum CodingKeys: String, CodingKey {
        case passed, reason, kind
        case evaluatedValue = "evaluated_value"
    }

    public init(
        passed: Bool,
        reason: String? = nil,
        kind: String? = nil,
        evaluatedValue: RPCJSONValue? = nil
    ) {
        self.passed = passed
        self.reason = reason
        self.kind = kind
        self.evaluatedValue = evaluatedValue
    }
}

/// One element of `actions_emitted[]` — what the dispatcher decided
/// for a single consequence. `status` is `emitted` / `failed` / `skipped`.
public struct RuleActionResult: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let kind: String
    public let execution: String   // sync | async | unknown
    public let status: String      // emitted | failed | skipped
    public let targetId: UUID?
    public let error: String?
    public let audience: String?
    public let recipients: Int?
    public let severity: Int?
    public let newState: String?

    public var id: String { "\(kind)|\(status)|\(targetId?.uuidString ?? "")" }

    enum CodingKeys: String, CodingKey {
        case kind, execution, status, error, audience, recipients, severity
        case targetId   = "target_id"
        case newState   = "new_state"
    }

    public init(
        kind: String,
        execution: String,
        status: String,
        targetId: UUID? = nil,
        error: String? = nil,
        audience: String? = nil,
        recipients: Int? = nil,
        severity: Int? = nil,
        newState: String? = nil
    ) {
        self.kind = kind
        self.execution = execution
        self.status = status
        self.targetId = targetId
        self.error = error
        self.audience = audience
        self.recipients = recipients
        self.severity = severity
        self.newState = newState
    }
}

public extension RuleActionResult {
    var isSync: Bool { execution == "sync" }
    var isEmitted: Bool { status == "emitted" }
    var isFailed: Bool { status == "failed" }
}

public struct GroupRuleEvaluation: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let id: UUID                          // evaluation_id
    public let ruleId: UUID
    public let ruleTitle: String
    public let ruleVersionId: UUID
    public let shapeKey: String?
    public let triggerEventType: String?
    public let sourceEventId: UUID?
    public let matched: Bool
    public let cycleDetected: Bool
    public let depth: Int
    public let matchedPredicate: RulePredicateOutcome?
    public let actionsEmitted: [RuleActionResult]
    public let parentEvaluationId: UUID?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id                  = "evaluation_id"
        case ruleId              = "rule_id"
        case ruleTitle           = "rule_title"
        case ruleVersionId       = "rule_version_id"
        case shapeKey            = "shape_key"
        case triggerEventType    = "trigger_event_type"
        case sourceEventId       = "source_event_id"
        case matched
        case cycleDetected       = "cycle_detected"
        case depth
        case matchedPredicate    = "matched_predicate"
        case actionsEmitted      = "actions_emitted"
        case parentEvaluationId  = "parent_evaluation_id"
        case createdAt           = "created_at"
    }

    public init(
        id: UUID,
        ruleId: UUID,
        ruleTitle: String,
        ruleVersionId: UUID,
        shapeKey: String? = nil,
        triggerEventType: String? = nil,
        sourceEventId: UUID? = nil,
        matched: Bool,
        cycleDetected: Bool = false,
        depth: Int = 0,
        matchedPredicate: RulePredicateOutcome? = nil,
        actionsEmitted: [RuleActionResult] = [],
        parentEvaluationId: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.ruleId = ruleId
        self.ruleTitle = ruleTitle
        self.ruleVersionId = ruleVersionId
        self.shapeKey = shapeKey
        self.triggerEventType = triggerEventType
        self.sourceEventId = sourceEventId
        self.matched = matched
        self.cycleDetected = cycleDetected
        self.depth = depth
        self.matchedPredicate = matchedPredicate
        self.actionsEmitted = actionsEmitted
        self.parentEvaluationId = parentEvaluationId
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.ruleId = try c.decode(UUID.self, forKey: .ruleId)
        self.ruleTitle = try c.decode(String.self, forKey: .ruleTitle)
        self.ruleVersionId = try c.decode(UUID.self, forKey: .ruleVersionId)
        self.shapeKey = try c.decodeIfPresent(String.self, forKey: .shapeKey)
        self.triggerEventType = try c.decodeIfPresent(String.self, forKey: .triggerEventType)
        self.sourceEventId = try c.decodeIfPresent(UUID.self, forKey: .sourceEventId)
        self.matched = try c.decode(Bool.self, forKey: .matched)
        self.cycleDetected = (try c.decodeIfPresent(Bool.self, forKey: .cycleDetected)) ?? false
        self.depth = (try c.decodeIfPresent(Int.self, forKey: .depth)) ?? 0
        self.matchedPredicate = try c.decodeIfPresent(RulePredicateOutcome.self, forKey: .matchedPredicate)
        self.actionsEmitted = (try c.decodeIfPresent([RuleActionResult].self, forKey: .actionsEmitted)) ?? []
        self.parentEvaluationId = try c.decodeIfPresent(UUID.self, forKey: .parentEvaluationId)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

public extension GroupRuleEvaluation {
    var hasActions: Bool { !actionsEmitted.isEmpty }
    var emittedActions: [RuleActionResult] { actionsEmitted.filter(\.isEmitted) }
    var failedActions: [RuleActionResult] { actionsEmitted.filter(\.isFailed) }

    /// Short headline for the row — "Coincidió y disparó N consecuencias"
    /// vs "No coincidió" vs "Ciclo detectado". Keeps the row readable
    /// without forcing the user into the detail layer.
    var summary: String {
        if cycleDetected {
            return "Ciclo detectado — sin disparo"
        }
        if !matched {
            return "No coincidió"
        }
        if emittedActions.isEmpty && failedActions.isEmpty {
            return "Coincidió sin consecuencias"
        }
        var parts: [String] = []
        if !emittedActions.isEmpty {
            parts.append("\(emittedActions.count) emitida\(emittedActions.count == 1 ? "" : "s")")
        }
        if !failedActions.isEmpty {
            parts.append("\(failedActions.count) fallida\(failedActions.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}
