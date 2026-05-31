import Foundation

// MARK: - System event engine provenance (V2-G8.2)
//
// "¿Por qué pasó esto?" sheet payload. Hydrated via
// `system_event_engine_provenance(p_event_uuid_id)` — reverse lookup
// from a group_events row into the rule evaluation that originated it
// (if any). Doctrina: transparencia primero. Si el evento NO fue
// causado por engine, `found=false` con `reason` indicando por qué
// (event_type_not_engine_actionable | no_engine_origin | event_not_found),
// y la UI renderea "esto lo registró @actor manualmente".

/// Lightweight projection of the event that triggered the rule. UI
/// renders it as "Disparado por <event_type> de <actor> el <occurredAt>".
public struct ProvenanceSourceEvent: Codable, Sendable, Hashable, Equatable {
    public let eventUuid: UUID
    public let eventType: String
    public let actorUserId: UUID?
    public let occurredAt: Date?
    public let summary: String?

    enum CodingKeys: String, CodingKey {
        case eventUuid    = "event_uuid"
        case eventType    = "event_type"
        case actorUserId  = "actor_user_id"
        case occurredAt   = "occurred_at"
        case summary
    }
}

public struct SystemEventProvenance: Codable, Sendable, Hashable, Equatable {
    public let found: Bool
    public let reason: String?

    // Populated when found == true:
    public let evaluationId: UUID?
    public let ruleVersionId: UUID?
    public let ruleTitle: String?
    public let matchedPredicate: RulePredicateOutcome?
    public let cycleDetected: Bool?
    public let depth: Int?
    public let evaluatedAt: Date?
    public let sourceEvent: ProvenanceSourceEvent?

    // V3-D.17 — enrichment carried back by the extended provenance RPC.
    // Lets the sheet render "ejecutó consequence.create_pool_charge →
    // obligation" without a second hop. Nil on legacy payloads.
    public let consequenceKind: String?
    public let targetKind: String?
    public let targetId: UUID?

    // Populated when found == false on the "not engine actionable" /
    // "no engine origin" branches — gives the UI enough to render the
    // human attribution fallback without a second hop.
    public let eventType: String?
    public let actorUserId: UUID?

    enum CodingKeys: String, CodingKey {
        case found, reason
        case evaluationId      = "evaluation_id"
        case ruleVersionId     = "rule_version_id"
        case ruleTitle         = "rule_title"
        case matchedPredicate  = "matched_predicate"
        case cycleDetected     = "cycle_detected"
        case depth
        case evaluatedAt       = "evaluated_at"
        case sourceEvent       = "source_event"
        case consequenceKind   = "consequence_kind"
        case targetKind        = "target_kind"
        case targetId          = "target_id"
        case eventType         = "event_type"
        case actorUserId       = "actor_user_id"
    }

    public init(
        found: Bool,
        reason: String? = nil,
        evaluationId: UUID? = nil,
        ruleVersionId: UUID? = nil,
        ruleTitle: String? = nil,
        matchedPredicate: RulePredicateOutcome? = nil,
        cycleDetected: Bool? = nil,
        depth: Int? = nil,
        evaluatedAt: Date? = nil,
        sourceEvent: ProvenanceSourceEvent? = nil,
        consequenceKind: String? = nil,
        targetKind: String? = nil,
        targetId: UUID? = nil,
        eventType: String? = nil,
        actorUserId: UUID? = nil
    ) {
        self.found = found
        self.reason = reason
        self.evaluationId = evaluationId
        self.ruleVersionId = ruleVersionId
        self.ruleTitle = ruleTitle
        self.matchedPredicate = matchedPredicate
        self.cycleDetected = cycleDetected
        self.depth = depth
        self.evaluatedAt = evaluatedAt
        self.sourceEvent = sourceEvent
        self.consequenceKind = consequenceKind
        self.targetKind = targetKind
        self.targetId = targetId
        self.eventType = eventType
        self.actorUserId = actorUserId
    }
}
