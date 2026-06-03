import Foundation

// MARK: - Obligations (fila de `obligations`)

public struct Obligation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID?
    public let debtorActorId: UUID
    public let creditorActorId: UUID
    public let obligationType: String
    public let amount: Double?
    public let currency: String?
    public let status: String
    public let dueAt: Date?
    public let sourceEventId: UUID?
    public let sourceRuleId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case debtorActorId = "debtor_actor_id"
        case creditorActorId = "creditor_actor_id"
        case obligationType = "obligation_type"
        case amount
        case currency
        case status
        case dueAt = "due_at"
        case sourceEventId = "source_event_id"
        case sourceRuleId = "source_rule_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        debtorActorId: UUID,
        creditorActorId: UUID,
        obligationType: String,
        amount: Double? = nil,
        currency: String? = nil,
        status: String = "open",
        dueAt: Date? = nil,
        sourceEventId: UUID? = nil,
        sourceRuleId: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.debtorActorId = debtorActorId
        self.creditorActorId = creditorActorId
        self.obligationType = obligationType
        self.amount = amount
        self.currency = currency
        self.status = status
        self.dueAt = dueAt
        self.sourceEventId = sourceEventId
        self.sourceRuleId = sourceRuleId
        self.createdAt = createdAt
    }

    public var isOpen: Bool { status == "open" }

    public var typeLabel: String {
        switch obligationType {
        case "fine": return "Multa"
        case "expense_share": return "Parte de gasto"
        case "game_debt": return "Deuda de juego"
        // R.2N: los ious son saldos neteados por el settlement vivo.
        case "iou": return "Saldo neto"
        case "contribution": return "Aportación"
        case "dues": return "Cuota"
        case "trip_share": return "Parte de viaje"
        case "sanction": return "Sanción"
        case "loan": return "Préstamo"
        case "reservation_fee": return "Cuota de reservación"
        default: return obligationType
        }
    }

    public var statusLabel: String {
        switch status {
        case "open": return "Abierta"
        case "settled": return "Liquidada"
        case "forgiven": return "Perdonada"
        case "disputed": return "En disputa"
        case "cancelled": return "Cancelada"
        default: return status
        }
    }
}

// MARK: - Resultados de record_expense / record_game_result

/// Obligación creada por un gasto (`record_expense().obligations[]`).
public struct ExpenseObligation: Codable, Sendable, Equatable, Identifiable {
    public let obligationId: UUID
    public let debtor: UUID
    public let amount: Double

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case debtor
        case amount
    }

    public init(obligationId: UUID, debtor: UUID, amount: Double) {
        self.obligationId = obligationId
        self.debtor = debtor
        self.amount = amount
    }

    public var id: UUID { obligationId }
}

/// Resultado de `record_expense()`.
public struct ExpenseResult: Decodable, Sendable, Equatable {
    public let transactionId: UUID
    public let sharePerPerson: Double?
    public let splitMethod: String?
    public let obligations: [ExpenseObligation]
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case sharePerPerson = "share_per_person"
        case splitMethod = "split_method"
        case obligations
        case idempotentReplay = "idempotent_replay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.transactionId = try c.decode(UUID.self, forKey: .transactionId)
        self.sharePerPerson = try c.decodeIfPresent(Double.self, forKey: .sharePerPerson)
        self.splitMethod = try c.decodeIfPresent(String.self, forKey: .splitMethod)
        self.obligations = try c.decodeIfPresent([ExpenseObligation].self, forKey: .obligations) ?? []
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }

    public init(transactionId: UUID, sharePerPerson: Double? = nil, splitMethod: String? = nil, obligations: [ExpenseObligation] = [], idempotentReplay: Bool = false) {
        self.transactionId = transactionId
        self.sharePerPerson = sharePerPerson
        self.splitMethod = splitMethod
        self.obligations = obligations
        self.idempotentReplay = idempotentReplay
    }
}

/// Resultado de `record_game_result()`.
public struct GameResultRecorded: Decodable, Sendable, Equatable {
    public let transactionId: UUID
    public let obligationId: UUID?
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case obligationId = "obligation_id"
        case idempotentReplay = "idempotent_replay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.transactionId = try c.decode(UUID.self, forKey: .transactionId)
        self.obligationId = try c.decodeIfPresent(UUID.self, forKey: .obligationId)
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }

    public init(transactionId: UUID, obligationId: UUID? = nil, idempotentReplay: Bool = false) {
        self.transactionId = transactionId
        self.obligationId = obligationId
        self.idempotentReplay = idempotentReplay
    }
}

// MARK: - Settlement

/// Fila de `settlement_batches`.
public struct SettlementBatch: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID?
    public let status: String
    public let currency: String
    public let createdAt: Date?
    public let finalizedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case status
        case currency
        case createdAt = "created_at"
        case finalizedAt = "finalized_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        status: String = "draft",
        currency: String,
        createdAt: Date? = nil,
        finalizedAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.status = status
        self.currency = currency
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
    }

    public var isFinalized: Bool { status == "finalized" }
}

/// Fila de `settlement_items`.
public struct SettlementItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let settlementBatchId: UUID
    public let fromActorId: UUID
    public let toActorId: UUID
    public let amount: Double
    public let currency: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case settlementBatchId = "settlement_batch_id"
        case fromActorId = "from_actor_id"
        case toActorId = "to_actor_id"
        case amount
        case currency
        case status
    }

    public init(
        id: UUID,
        settlementBatchId: UUID,
        fromActorId: UUID,
        toActorId: UUID,
        amount: Double,
        currency: String,
        status: String = "pending"
    ) {
        self.id = id
        self.settlementBatchId = settlementBatchId
        self.fromActorId = fromActorId
        self.toActorId = toActorId
        self.amount = amount
        self.currency = currency
        self.status = status
    }

    public var isPaid: Bool { status == "paid" }
    /// R.2N: items reemplazados por un recálculo del neteo vivo — no se muestran.
    public var isCancelled: Bool { status == "cancelled" }
}

/// Una transferencia sugerida (`generate_settlement_batch().items[]`).
public struct SettlementTransfer: Codable, Sendable, Equatable {
    public let from: UUID
    public let to: UUID
    public let amount: Double

    public init(from: UUID, to: UUID, amount: Double) {
        self.from = from
        self.to = to
        self.amount = amount
    }
}

/// Resultado de `generate_settlement_batch()`. `batchId == nil` cuando todo
/// neteó a cero y las obligations se liquidaron directamente.
public struct SettlementBatchResult: Decodable, Sendable, Equatable {
    public let batchId: UUID?
    public let items: [SettlementTransfer]
    public let message: String?
    public let obligationsNetted: Int?

    enum CodingKeys: String, CodingKey {
        case batchId = "batch_id"
        case items
        case message
        case obligationsNetted = "obligations_netted"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.batchId = try c.decodeIfPresent(UUID.self, forKey: .batchId)
        self.items = try c.decodeIfPresent([SettlementTransfer].self, forKey: .items) ?? []
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
        self.obligationsNetted = try c.decodeIfPresent(Int.self, forKey: .obligationsNetted)
    }

    public init(batchId: UUID?, items: [SettlementTransfer] = [], message: String? = nil, obligationsNetted: Int? = nil) {
        self.batchId = batchId
        self.items = items
        self.message = message
        self.obligationsNetted = obligationsNetted
    }
}

/// Resultado de `mark_settlement_paid()`.
public struct MarkPaidResult: Decodable, Sendable, Equatable {
    public let itemId: UUID
    public let transactionId: UUID?
    public let batchFinalized: Bool
    public let obligationsClosed: Int?
    public let alreadyPaid: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case transactionId = "transaction_id"
        case batchFinalized = "batch_finalized"
        case obligationsClosed = "obligations_closed"
        case alreadyPaid = "already_paid"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.itemId = try c.decode(UUID.self, forKey: .itemId)
        self.transactionId = try c.decodeIfPresent(UUID.self, forKey: .transactionId)
        self.batchFinalized = try c.decodeIfPresent(Bool.self, forKey: .batchFinalized) ?? false
        self.obligationsClosed = try c.decodeIfPresent(Int.self, forKey: .obligationsClosed)
        self.alreadyPaid = try c.decodeIfPresent(Bool.self, forKey: .alreadyPaid) ?? false
    }

    public init(itemId: UUID, transactionId: UUID? = nil, batchFinalized: Bool = false, obligationsClosed: Int? = nil, alreadyPaid: Bool = false) {
        self.itemId = itemId
        self.transactionId = transactionId
        self.batchFinalized = batchFinalized
        self.obligationsClosed = obligationsClosed
        self.alreadyPaid = alreadyPaid
    }
}

// MARK: - Formato de dinero

public extension Double {
    /// `"$1,300.00 MXN"` — formato estándar de montos en la app.
    func currencyLabel(_ currency: String?) -> String {
        let formatted = self.formatted(.number.precision(.fractionLength(2)))
        if let currency, !currency.isEmpty {
            return "$\(formatted) \(currency)"
        }
        return "$\(formatted)"
    }
}
