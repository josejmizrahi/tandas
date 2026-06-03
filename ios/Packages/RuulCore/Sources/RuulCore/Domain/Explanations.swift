import Foundation

/// R.2S.10 — Explanation engine. Cinco RPCs `why_*` que devuelven la razón
/// concreta por la cual el backend tomó una decisión (visibilidad, capacidad
/// de reservar, resultado de votación, ganador de conflicto, origen de
/// obligación). El frontend nunca infiere estos motivos — los muestra
/// verbatim al usuario.

/// `why_can_view_resource(actor, resource)`.
public struct WhyCanViewResource: Decodable, Sendable, Equatable {
    public let actorId: UUID
    public let resourceId: UUID
    public let canView: Bool
    public let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case resourceId = "resource_id"
        case canView = "can_view"
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.canView = try c.decodeIfPresent(Bool.self, forKey: .canView) ?? false
        self.reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    public init(actorId: UUID, resourceId: UUID, canView: Bool, reasons: [String] = []) {
        self.actorId = actorId
        self.resourceId = resourceId
        self.canView = canView
        self.reasons = reasons
    }
}

/// `why_can_reserve(actor, resource)`.
public struct WhyCanReserve: Decodable, Sendable, Equatable {
    public let actorId: UUID
    public let resourceId: UUID
    public let canReserve: Bool
    public let requiredCapability: String
    public let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case resourceId = "resource_id"
        case canReserve = "can_reserve"
        case requiredCapability = "required_capability"
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.canReserve = try c.decodeIfPresent(Bool.self, forKey: .canReserve) ?? false
        self.requiredCapability = try c.decodeIfPresent(String.self, forKey: .requiredCapability) ?? "reservable"
        self.reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    public init(actorId: UUID, resourceId: UUID, canReserve: Bool, requiredCapability: String = "reservable", reasons: [String] = []) {
        self.actorId = actorId
        self.resourceId = resourceId
        self.canReserve = canReserve
        self.requiredCapability = requiredCapability
        self.reasons = reasons
    }
}

/// `why_decision_result(decision)` — tally completo + razones humanas.
public struct WhyDecisionResult: Decodable, Sendable, Equatable {
    public let decisionId: UUID
    public let status: String
    public let votingModel: String
    public let tally: WhyDecisionTally
    /// option_title → votes count (single_choice / multiple_choice / approval).
    public let optionTally: [String: Double]
    public let activeMembers: Double
    public let result: JSONValue?
    public let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case status
        case votingModel = "voting_model"
        case tally
        case optionTally = "option_tally"
        case activeMembers = "active_members"
        case result
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.decisionId = try c.decode(UUID.self, forKey: .decisionId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.votingModel = try c.decodeIfPresent(String.self, forKey: .votingModel) ?? "yes_no_abstain"
        self.tally = try c.decodeIfPresent(WhyDecisionTally.self, forKey: .tally) ?? WhyDecisionTally()
        self.optionTally = try c.decodeIfPresent([String: Double].self, forKey: .optionTally) ?? [:]
        self.activeMembers = try c.decodeIfPresent(Double.self, forKey: .activeMembers) ?? 0
        self.result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        self.reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    public init(
        decisionId: UUID,
        status: String,
        votingModel: String,
        tally: WhyDecisionTally = WhyDecisionTally(),
        optionTally: [String: Double] = [:],
        activeMembers: Double = 0,
        result: JSONValue? = nil,
        reasons: [String] = []
    ) {
        self.decisionId = decisionId
        self.status = status
        self.votingModel = votingModel
        self.tally = tally
        self.optionTally = optionTally
        self.activeMembers = activeMembers
        self.result = result
        self.reasons = reasons
    }
}

public struct WhyDecisionTally: Decodable, Sendable, Equatable {
    public let approve: Double
    public let reject: Double
    public let abstain: Double

    enum CodingKeys: String, CodingKey { case approve, reject, abstain }

    public init(approve: Double = 0, reject: Double = 0, abstain: Double = 0) {
        self.approve = approve
        self.reject = reject
        self.abstain = abstain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.approve = try c.decodeIfPresent(Double.self, forKey: .approve) ?? 0
        self.reject = try c.decodeIfPresent(Double.self, forKey: .reject) ?? 0
        self.abstain = try c.decodeIfPresent(Double.self, forKey: .abstain) ?? 0
    }
}

/// `why_reservation_won(conflict)`.
public struct WhyReservationWon: Decodable, Sendable, Equatable {
    public let conflictId: UUID
    public let resolutionStatus: String
    public let winnerReservationId: UUID?
    public let winnerActorId: UUID?
    public let recommendedWinnerActorId: UUID?
    public let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case conflictId = "conflict_id"
        case resolutionStatus = "resolution_status"
        case winnerReservationId = "winner_reservation_id"
        case winnerActorId = "winner_actor_id"
        case recommendedWinnerActorId = "recommended_winner_actor_id"
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.conflictId = try c.decode(UUID.self, forKey: .conflictId)
        self.resolutionStatus = try c.decodeIfPresent(String.self, forKey: .resolutionStatus) ?? "open"
        self.winnerReservationId = try c.decodeIfPresent(UUID.self, forKey: .winnerReservationId)
        self.winnerActorId = try c.decodeIfPresent(UUID.self, forKey: .winnerActorId)
        self.recommendedWinnerActorId = try c.decodeIfPresent(UUID.self, forKey: .recommendedWinnerActorId)
        self.reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    public init(
        conflictId: UUID,
        resolutionStatus: String,
        winnerReservationId: UUID? = nil,
        winnerActorId: UUID? = nil,
        recommendedWinnerActorId: UUID? = nil,
        reasons: [String] = []
    ) {
        self.conflictId = conflictId
        self.resolutionStatus = resolutionStatus
        self.winnerReservationId = winnerReservationId
        self.winnerActorId = winnerActorId
        self.recommendedWinnerActorId = recommendedWinnerActorId
        self.reasons = reasons
    }
}

/// `why_obligation_exists(obligation)` — origen + razón humana.
public struct WhyObligationExists: Decodable, Sendable, Equatable {
    public let obligationId: UUID
    public let kind: String
    public let source: String
    public let reason: String
    public let sourceRuleId: UUID?
    public let sourceDecisionId: UUID?
    public let sourceEventId: UUID?
    public let sourceReservationId: UUID?
    public let ruleTitle: String?
    public let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case kind
        case source
        case reason
        case sourceRuleId = "source_rule_id"
        case sourceDecisionId = "source_decision_id"
        case sourceEventId = "source_event_id"
        case sourceReservationId = "source_reservation_id"
        case ruleTitle = "rule_title"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.obligationId = try c.decode(UUID.self, forKey: .obligationId)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "money"
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.sourceRuleId = try c.decodeIfPresent(UUID.self, forKey: .sourceRuleId)
        self.sourceDecisionId = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        self.sourceEventId = try c.decodeIfPresent(UUID.self, forKey: .sourceEventId)
        self.sourceReservationId = try c.decodeIfPresent(UUID.self, forKey: .sourceReservationId)
        self.ruleTitle = try c.decodeIfPresent(String.self, forKey: .ruleTitle)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }

    public init(
        obligationId: UUID,
        kind: String,
        source: String,
        reason: String,
        sourceRuleId: UUID? = nil,
        sourceDecisionId: UUID? = nil,
        sourceEventId: UUID? = nil,
        sourceReservationId: UUID? = nil,
        ruleTitle: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.obligationId = obligationId
        self.kind = kind
        self.source = source
        self.reason = reason
        self.sourceRuleId = sourceRuleId
        self.sourceDecisionId = sourceDecisionId
        self.sourceEventId = sourceEventId
        self.sourceReservationId = sourceReservationId
        self.ruleTitle = ruleTitle
        self.metadata = metadata
    }
}
