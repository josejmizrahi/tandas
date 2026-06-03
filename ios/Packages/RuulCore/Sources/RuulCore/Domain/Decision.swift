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

/// Fila de `decisions`.
public struct Decision: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID
    public let decisionType: String
    public let title: String
    public let description: String?
    public let status: String
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
        self.createdByActorId = createdByActorId
        self.closesAt = closesAt
        self.decidedAt = decidedAt
        self.executedAt = executedAt
        self.payload = payload
        self.result = result
        self.createdAt = createdAt
    }

    public var type: DecisionType { DecisionType(rawValue: decisionType) ?? .generic }
    public var isOpen: Bool { status == "open" }
    public var isApproved: Bool { status == "approved" }
    public var isExecuted: Bool { status == "executed" }

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
    public let votedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case decisionId = "decision_id"
        case voterActorId = "voter_actor_id"
        case vote
        case votedAt = "voted_at"
    }

    public init(id: UUID, decisionId: UUID, voterActorId: UUID, vote: String, votedAt: Date? = nil) {
        self.id = id
        self.decisionId = decisionId
        self.voterActorId = voterActorId
        self.vote = vote
        self.votedAt = votedAt
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

/// Resultado de `vote_decision()` / `close_decision()`.
public struct VoteResult: Decodable, Sendable, Equatable {
    public let decisionId: UUID
    public let myVote: String?
    public let status: String
    public let winningOption: String?
    public let tally: VoteTally?

    enum CodingKeys: String, CodingKey {
        case decisionId = "decision_id"
        case myVote = "my_vote"
        case status
        case winningOption = "winning_option"
        case tally
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.decisionId = try c.decode(UUID.self, forKey: .decisionId)
        self.myVote = try c.decodeIfPresent(String.self, forKey: .myVote)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.winningOption = try c.decodeIfPresent(String.self, forKey: .winningOption)
        self.tally = try c.decodeIfPresent(VoteTally.self, forKey: .tally)
    }

    public init(decisionId: UUID, myVote: String? = nil, status: String = "open", winningOption: String? = nil, tally: VoteTally? = nil) {
        self.decisionId = decisionId
        self.myVote = myVote
        self.status = status
        self.winningOption = winningOption
        self.tally = tally
    }
}
