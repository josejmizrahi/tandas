import Foundation

public enum DecisionType: String, Codable, Sendable, CaseIterable, Identifiable {
    case expenseApproval = "expense_approval"
    case ruleChange = "rule_change"
    case memberAdmission = "member_admission"
    case resourcePurchase = "resource_purchase"
    case reservationDispute = "reservation_dispute"
    case generic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .expenseApproval: return "Aprobar gasto"
        case .ruleChange: return "Cambio de regla"
        case .memberAdmission: return "Admisión de miembro"
        case .resourcePurchase: return "Compra de recurso"
        case .reservationDispute: return "Disputa de reservación"
        case .generic: return "General"
        }
    }
}

public enum VoteChoice: String, Codable, Sendable, CaseIterable {
    case approve, reject, abstain

    public var label: String {
        switch self {
        case .approve: return "A favor"
        case .reject: return "En contra"
        case .abstain: return "Abstención"
        }
    }
}

public enum VotingModel: String, Codable, Sendable, CaseIterable {
    case yesNoAbstain = "yes_no_abstain"
    case singleChoice = "single_choice"
    case multipleChoice = "multiple_choice"
    case rankedChoice = "ranked_choice"
    case approvalVote = "approval_vote"
    case numericAllocation = "numeric_allocation"
    case consent

    public var label: String {
        switch self {
        case .yesNoAbstain: return "Sí / No / Abstención"
        case .singleChoice: return "Elegir una opción"
        case .multipleChoice: return "Elegir varias"
        case .rankedChoice: return "Ordenar por preferencia"
        case .approvalVote: return "Aprobar varias"
        case .numericAllocation: return "Repartir presupuesto"
        case .consent: return "Consentimiento"
        }
    }
}

/// Fila de `decisions`.
public struct Decision: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID
    public let decisionType: String
    public let title: String
    public let description: String?
    public let status: String
    public let votingModel: String
    public let createdByActorId: UUID?
    public let closesAt: Date?
    public let decidedAt: Date?
    public let executedAt: Date?
    public let payload: JSONValue?
    public let result: JSONValue?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case decisionType = "decision_type"
        case title
        case description
        case status
        case votingModel = "voting_model"
        case createdByActorId = "created_by_actor_id"
        case closesAt = "closes_at"
        case decidedAt = "decided_at"
        case executedAt = "executed_at"
        case payload
        case result
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID,
        decisionType: String,
        title: String,
        description: String? = nil,
        status: String = "open",
        votingModel: String = "yes_no_abstain",
        createdByActorId: UUID? = nil,
        closesAt: Date? = nil,
        decidedAt: Date? = nil,
        executedAt: Date? = nil,
        payload: JSONValue? = nil,
        result: JSONValue? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.decisionType = decisionType
        self.title = title
        self.description = description
        self.status = status
        self.votingModel = votingModel
        self.createdByActorId = createdByActorId
        self.closesAt = closesAt
        self.decidedAt = decidedAt
        self.executedAt = executedAt
        self.payload = payload
        self.result = result
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.decisionType = try c.decode(String.self, forKey: .decisionType)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.votingModel = try c.decodeIfPresent(String.self, forKey: .votingModel) ?? "yes_no_abstain"
        self.createdByActorId = try c.decodeIfPresent(UUID.self, forKey: .createdByActorId)
        self.closesAt = try c.decodeIfPresent(Date.self, forKey: .closesAt)
        self.decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        self.executedAt = try c.decodeIfPresent(Date.self, forKey: .executedAt)
        self.payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload)
        self.result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var type: DecisionType { DecisionType(rawValue: decisionType) ?? .generic }
    public var voting: VotingModel { VotingModel(rawValue: votingModel) ?? .yesNoAbstain }
    public var isOpen: Bool { status == "open" }
    public var isApproved: Bool { status == "approved" }
    public var isExecuted: Bool { status == "executed" }

    /// Clave de la opción ganadora (`option_key`) tras cerrar la votación.
    public var winningOptionKey: String? {
        result?["winning_option"]?.stringValue
    }

    /// UUID de la opción ganadora (R.2Q).
    public var winningOptionId: UUID? {
        guard let raw = result?["winning_option_id"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    public var statusLabel: String {
        switch status {
        case "open": return "Abierta"
        case "approved": return "Aprobada"
        case "rejected": return "Rechazada"
        case "executed": return "Ejecutada"
        case "cancelled": return "Cancelada"
        default: return status
        }
    }
}

/// Fila de `decision_options` — alternativa concreta que un votante puede elegir.
public struct DecisionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let decisionId: UUID
    public let optionKey: String
    public let title: String
    public let description: String?
    public let payload: JSONValue?
    public let sortOrder: Int
    public let status: String
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case decisionId = "decision_id"
        case optionKey = "option_key"
        case title
        case description
        case payload
        case sortOrder = "sort_order"
        case status
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        decisionId: UUID,
        optionKey: String,
        title: String,
        description: String? = nil,
        payload: JSONValue? = nil,
        sortOrder: Int = 0,
        status: String = "active",
        createdAt: Date? = nil
    ) {
        self.id = id
        self.decisionId = decisionId
        self.optionKey = optionKey
        self.title = title
        self.description = description
        self.payload = payload
        self.sortOrder = sortOrder
        self.status = status
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.decisionId = try c.decode(UUID.self, forKey: .decisionId)
        self.optionKey = try c.decode(String.self, forKey: .optionKey)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload)
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var isActive: Bool { status == "active" }

    /// Acción que `execute_decision` invocará si esta opción gana (R.2Q).
    public var actionKey: String? { payload?["action"]?.stringValue }
}

/// Resultado de `create_decision()`.
public struct DecisionCreated: Decodable, Sendable, Equatable {
    public let decisionId: UUID
    public let decision: Decision

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case decision
    }
}

/// Fila de `decision_votes`.
public struct DecisionVote: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let decisionId: UUID
    public let voterActorId: UUID
    public let vote: String
    public let optionId: UUID?
    public let votedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case decisionId = "decision_id"
        case voterActorId = "voter_actor_id"
        case vote
        case optionId = "option_id"
        case votedAt = "voted_at"
    }

    public init(
        id: UUID,
        decisionId: UUID,
        voterActorId: UUID,
        vote: String,
        optionId: UUID? = nil,
        votedAt: Date? = nil
    ) {
        self.id = id
        self.decisionId = decisionId
        self.voterActorId = voterActorId
        self.vote = vote
        self.optionId = optionId
        self.votedAt = votedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.decisionId = try c.decode(UUID.self, forKey: .decisionId)
        self.voterActorId = try c.decode(UUID.self, forKey: .voterActorId)
        self.vote = try c.decode(String.self, forKey: .vote)
        self.optionId = try c.decodeIfPresent(UUID.self, forKey: .optionId)
        self.votedAt = try c.decodeIfPresent(Date.self, forKey: .votedAt)
    }

    public var choice: VoteChoice? { VoteChoice(rawValue: vote) }
}

/// Conteo de votos (de `vote_decision().tally` / `close_decision().tally`).
public struct VoteTally: Codable, Sendable, Equatable {
    public let approve: Int
    public let reject: Int
    public let members: Int

    public init(approve: Int = 0, reject: Int = 0, members: Int = 0) {
        self.approve = approve
        self.reject = reject
        self.members = members
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.approve = try c.decodeIfPresent(Int.self, forKey: .approve) ?? 0
        self.reject = try c.decodeIfPresent(Int.self, forKey: .reject) ?? 0
        self.members = try c.decodeIfPresent(Int.self, forKey: .members) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case approve, reject, members
    }
}

/// Resultado de `vote_decision()` / `close_decision()` / `vote_for_option()`.
public struct VoteResult: Decodable, Sendable, Equatable {
    public let decisionId: UUID
    public let myVote: String?
    public let myOptionId: UUID?
    public let status: String
    public let winningOption: String?
    public let winningOptionId: UUID?
    public let tally: VoteTally?

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case myVote = "my_vote"
        case myOptionId = "my_option_id"
        case status
        case winningOption = "winning_option"
        case winningOptionId = "winning_option_id"
        case tally
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.decisionId = try c.decode(UUID.self, forKey: .decisionId)
        self.myVote = try c.decodeIfPresent(String.self, forKey: .myVote)
        self.myOptionId = try c.decodeIfPresent(UUID.self, forKey: .myOptionId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.winningOption = try c.decodeIfPresent(String.self, forKey: .winningOption)
        self.winningOptionId = try c.decodeIfPresent(UUID.self, forKey: .winningOptionId)
        self.tally = try c.decodeIfPresent(VoteTally.self, forKey: .tally)
    }

    public init(
        decisionId: UUID,
        myVote: String? = nil,
        myOptionId: UUID? = nil,
        status: String = "open",
        winningOption: String? = nil,
        winningOptionId: UUID? = nil,
        tally: VoteTally? = nil
    ) {
        self.decisionId = decisionId
        self.myVote = myVote
        self.myOptionId = myOptionId
        self.status = status
        self.winningOption = winningOption
        self.winningOptionId = winningOptionId
        self.tally = tally
    }
}
