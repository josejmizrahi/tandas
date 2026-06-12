import Foundation

/// Fila de `money_transactions` (R.4C / audit_9). El ledger crudo del contexto:
/// gastos, pagos, liquidaciones, aportes, payouts y resultados de juego. Lectura
/// PostgREST (RLS: creador, partes from/to, o miembros del contexto).
public struct MoneyTransaction: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID?
    public let fromActorId: UUID?
    public let toActorId: UUID?
    public let transactionType: String
    public let amount: Double
    public let currency: String
    public let status: String
    public let occurredAt: Date?
    public let resourceId: UUID?
    public let decisionId: UUID?
    public let eventId: UUID?
    public let obligationId: UUID?
    public let metadata: JSONValue
    public let createdByActorId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case fromActorId = "from_actor_id"
        case toActorId = "to_actor_id"
        case transactionType = "transaction_type"
        case amount
        case currency
        case status
        case occurredAt = "occurred_at"
        case resourceId = "resource_id"
        case decisionId = "decision_id"
        case eventId = "event_id"
        case obligationId = "obligation_id"
        case metadata
        case createdByActorId = "created_by_actor_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        fromActorId: UUID? = nil,
        toActorId: UUID? = nil,
        transactionType: String,
        amount: Double,
        currency: String,
        status: String = "posted",
        occurredAt: Date? = nil,
        resourceId: UUID? = nil,
        decisionId: UUID? = nil,
        eventId: UUID? = nil,
        obligationId: UUID? = nil,
        metadata: JSONValue = .object([:]),
        createdByActorId: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.fromActorId = fromActorId
        self.toActorId = toActorId
        self.transactionType = transactionType
        self.amount = amount
        self.currency = currency
        self.status = status
        self.occurredAt = occurredAt
        self.resourceId = resourceId
        self.decisionId = decisionId
        self.eventId = eventId
        self.obligationId = obligationId
        self.metadata = metadata
        self.createdByActorId = createdByActorId
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.fromActorId = try c.decodeIfPresent(UUID.self, forKey: .fromActorId)
        self.toActorId = try c.decodeIfPresent(UUID.self, forKey: .toActorId)
        self.transactionType = try c.decode(String.self, forKey: .transactionType)
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "MXN"
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "posted"
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        self.resourceId = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.decisionId = try c.decodeIfPresent(UUID.self, forKey: .decisionId)
        self.eventId = try c.decodeIfPresent(UUID.self, forKey: .eventId)
        self.obligationId = try c.decodeIfPresent(UUID.self, forKey: .obligationId)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata) ?? .object([:])
        self.createdByActorId = try c.decodeIfPresent(UUID.self, forKey: .createdByActorId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var isPosted: Bool { status == "posted" }
    public var isVoided: Bool { status == "voided" }
    /// Las liquidaciones se revierten por el handshake (confirm/reject/appeal),
    /// no por `void_transaction` — el backend rechaza el void de settlement.
    public var isSettlement: Bool { transactionType == "settlement" }

    public var typeLabel: String {
        switch transactionType {
        case "expense": return "Gasto"
        case "payment": return "Pago"
        case "settlement": return "Liquidación"
        case "contribution": return "Aportación"
        case "payout": return "Reparto"
        case "game_result": return "Resultado de juego"
        case "other": return "Otro"
        default: return transactionType
        }
    }

    public var statusLabel: String {
        switch status {
        case "posted": return "Registrado"
        case "voided": return "Anulado"
        default: return status
        }
    }

    /// Glosa humana de la transacción si el backend la guardó en metadata.
    public var note: String? {
        for key in ["description", "reason", "note", "game_name"] {
            if let value = metadata[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    /// Motivo de anulación (lo guarda `void_transaction` en metadata).
    public var voidReason: String? {
        metadata["void_reason"]?.stringValue
    }
}

/// Resultado de `void_transaction(p_transaction_id, p_reason?)` (audit_9).
public struct TransactionVoided: Decodable, Sendable, Equatable {
    public let transactionId: UUID
    public let status: String
    public let cancelledObligations: [UUID]
    public let reversedLedgerEntries: Int
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case status
        case cancelledObligations = "cancelled_obligations"
        case reversedLedgerEntries = "reversed_ledger_entries"
        case idempotentReplay = "idempotent_replay"
    }

    public init(
        transactionId: UUID,
        status: String = "voided",
        cancelledObligations: [UUID] = [],
        reversedLedgerEntries: Int = 0,
        idempotentReplay: Bool = false
    ) {
        self.transactionId = transactionId
        self.status = status
        self.cancelledObligations = cancelledObligations
        self.reversedLedgerEntries = reversedLedgerEntries
        self.idempotentReplay = idempotentReplay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.transactionId = try c.decode(UUID.self, forKey: .transactionId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "voided"
        self.cancelledObligations = try c.decodeIfPresent([UUID].self, forKey: .cancelledObligations) ?? []
        self.reversedLedgerEntries = try c.decodeIfPresent(Int.self, forKey: .reversedLedgerEntries) ?? 0
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }
}
