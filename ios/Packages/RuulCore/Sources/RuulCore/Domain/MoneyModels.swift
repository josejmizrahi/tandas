import Foundation

// MARK: - Obligations (fila de `obligations`)

public struct Obligation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID?
    public let debtorActorId: UUID
    public let creditorActorId: UUID
    public let obligationType: String
    /// R.2R — kind universal: money | action | approval | delivery | attendance | document | reservation | custom.
    public let obligationKind: String
    public let amount: Double?
    public let currency: String?
    public let status: String
    public let dueAt: Date?
    public let sourceEventId: UUID?
    public let sourceRuleId: UUID?
    public let sourceDecisionId: UUID?
    public let sourceReservationId: UUID?
    /// R.2R — título humano para obligaciones de acción.
    public let title: String?
    public let description: String?
    public let completedAt: Date?
    public let completedByActorId: UUID?
    public let completionNotes: String?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case debtorActorId = "debtor_actor_id"
        case creditorActorId = "creditor_actor_id"
        case obligationType = "obligation_type"
        case obligationKind = "obligation_kind"
        case amount
        case currency
        case status
        case dueAt = "due_at"
        case sourceEventId = "source_event_id"
        case sourceRuleId = "source_rule_id"
        case sourceDecisionId = "source_decision_id"
        case sourceReservationId = "source_reservation_id"
        case title
        case description
        case completedAt = "completed_at"
        case completedByActorId = "completed_by_actor_id"
        case completionNotes = "completion_notes"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.debtorActorId = try c.decode(UUID.self, forKey: .debtorActorId)
        self.creditorActorId = try c.decode(UUID.self, forKey: .creditorActorId)
        self.obligationType = try c.decode(String.self, forKey: .obligationType)
        self.obligationKind = try c.decodeIfPresent(String.self, forKey: .obligationKind) ?? "money"
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        self.sourceEventId = try c.decodeIfPresent(UUID.self, forKey: .sourceEventId)
        self.sourceRuleId = try c.decodeIfPresent(UUID.self, forKey: .sourceRuleId)
        self.sourceDecisionId = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        self.sourceReservationId = try c.decodeIfPresent(UUID.self, forKey: .sourceReservationId)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.completedByActorId = try c.decodeIfPresent(UUID.self, forKey: .completedByActorId)
        self.completionNotes = try c.decodeIfPresent(String.self, forKey: .completionNotes)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        debtorActorId: UUID,
        creditorActorId: UUID,
        obligationType: String,
        obligationKind: String = "money",
        amount: Double? = nil,
        currency: String? = nil,
        status: String = "open",
        dueAt: Date? = nil,
        sourceEventId: UUID? = nil,
        sourceRuleId: UUID? = nil,
        sourceDecisionId: UUID? = nil,
        sourceReservationId: UUID? = nil,
        title: String? = nil,
        description: String? = nil,
        completedAt: Date? = nil,
        completedByActorId: UUID? = nil,
        completionNotes: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.debtorActorId = debtorActorId
        self.creditorActorId = creditorActorId
        self.obligationType = obligationType
        self.obligationKind = obligationKind
        self.amount = amount
        self.currency = currency
        self.status = status
        self.dueAt = dueAt
        self.sourceEventId = sourceEventId
        self.sourceRuleId = sourceRuleId
        self.sourceDecisionId = sourceDecisionId
        self.sourceReservationId = sourceReservationId
        self.title = title
        self.description = description
        self.completedAt = completedAt
        self.completedByActorId = completedByActorId
        self.completionNotes = completionNotes
        self.createdAt = createdAt
    }

    public var isOpen: Bool { status == "open" }
    public var isCompleted: Bool { status == "completed" }
    /// R.2R — `money` se settlea, los demás kinds se completan.
    public var isMoneyKind: Bool { obligationKind == "money" }
    /// R.2R — kind ∈ action/approval/delivery/attendance/document/reservation/custom.
    public var isActionKind: Bool { !isMoneyKind }

    public var typeLabel: String {
        // R.2R: para kinds no-money preferimos `title` (es la descripción humana).
        if isActionKind, let title, !title.isEmpty { return title }
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

    public var kindLabel: String {
        switch obligationKind {
        case "money": return "Dinero"
        case "action": return "Acción"
        case "approval": return "Aprobación"
        case "delivery": return "Entrega"
        case "attendance": return "Asistencia"
        case "document": return "Documento"
        case "reservation": return "Reservación"
        case "custom": return "Otro"
        default: return obligationKind
        }
    }

    public var statusLabel: String {
        switch status {
        case "open": return "Abierta"
        case "accepted": return "Aceptada"
        case "in_progress": return "En progreso"
        case "completed": return "Cumplida"
        case "expired": return "Vencida"
        case "settled": return "Liquidada"
        case "forgiven": return "Perdonada"
        case "disputed": return "En disputa"
        case "cancelled": return "Cancelada"
        default: return status
        }
    }
}

// MARK: - R.2R Obligation detail + create/complete results

/// `obligation_detail(p_obligation_id)` — incluye `available_actions` canónicos.
public struct ObligationDetail: Decodable, Sendable, Equatable {
    public let id: UUID
    public let contextActorId: UUID?
    public let kind: String
    public let obligationType: String
    public let status: String
    public let title: String?
    public let description: String?
    public let amount: Double?
    public let currency: String?
    public let dueAt: Date?
    public let debtorActorId: UUID
    public let creditorActorId: UUID
    public let completedAt: Date?
    public let completedByActorId: UUID?
    public let completionNotes: String?
    public let sourceEventId: UUID?
    public let sourceRuleId: UUID?
    public let sourceReservationId: UUID?
    public let sourceDecisionId: UUID?
    public let metadata: JSONValue?
    public let availableActions: [AvailableAction]
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case kind
        case obligationType = "obligation_type"
        case status
        case title
        case description
        case amount
        case currency
        case dueAt = "due_at"
        case debtorActorId = "debtor_actor_id"
        case creditorActorId = "creditor_actor_id"
        case completedAt = "completed_at"
        case completedByActorId = "completed_by_actor_id"
        case completionNotes = "completion_notes"
        case sourceEventId = "source_event_id"
        case sourceRuleId = "source_rule_id"
        case sourceReservationId = "source_reservation_id"
        case sourceDecisionId = "source_decision_id"
        case metadata
        case availableActions = "available_actions"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.contextActorId = try c.decodeIfPresent(UUID.self, forKey: .contextActorId)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "money"
        self.obligationType = try c.decodeIfPresent(String.self, forKey: .obligationType) ?? "other"
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        self.debtorActorId = try c.decode(UUID.self, forKey: .debtorActorId)
        self.creditorActorId = try c.decode(UUID.self, forKey: .creditorActorId)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.completedByActorId = try c.decodeIfPresent(UUID.self, forKey: .completedByActorId)
        self.completionNotes = try c.decodeIfPresent(String.self, forKey: .completionNotes)
        self.sourceEventId = try c.decodeIfPresent(UUID.self, forKey: .sourceEventId)
        self.sourceRuleId = try c.decodeIfPresent(UUID.self, forKey: .sourceRuleId)
        self.sourceReservationId = try c.decodeIfPresent(UUID.self, forKey: .sourceReservationId)
        self.sourceDecisionId = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        self.availableActions = try c.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        kind: String = "money",
        obligationType: String = "other",
        status: String = "open",
        title: String? = nil,
        description: String? = nil,
        amount: Double? = nil,
        currency: String? = nil,
        dueAt: Date? = nil,
        debtorActorId: UUID,
        creditorActorId: UUID,
        completedAt: Date? = nil,
        completedByActorId: UUID? = nil,
        completionNotes: String? = nil,
        sourceEventId: UUID? = nil,
        sourceRuleId: UUID? = nil,
        sourceReservationId: UUID? = nil,
        sourceDecisionId: UUID? = nil,
        metadata: JSONValue? = nil,
        availableActions: [AvailableAction] = [],
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.kind = kind
        self.obligationType = obligationType
        self.status = status
        self.title = title
        self.description = description
        self.amount = amount
        self.currency = currency
        self.dueAt = dueAt
        self.debtorActorId = debtorActorId
        self.creditorActorId = creditorActorId
        self.completedAt = completedAt
        self.completedByActorId = completedByActorId
        self.completionNotes = completionNotes
        self.sourceEventId = sourceEventId
        self.sourceRuleId = sourceRuleId
        self.sourceReservationId = sourceReservationId
        self.sourceDecisionId = sourceDecisionId
        self.metadata = metadata
        self.availableActions = availableActions
        self.createdAt = createdAt
    }

    public var isMoneyKind: Bool { kind == "money" }
    public func can(_ key: String) -> Bool { availableActions.can(key) }
    public func action(_ key: String) -> AvailableAction? { availableActions.enabled(key) }
}

/// Resultado de `create_action_obligation(...)`.
public struct ActionObligationCreated: Decodable, Sendable, Equatable {
    public let obligationId: UUID
    public let kind: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case kind
        case status
    }
}

/// Resultado de `complete_obligation(...)`.
public struct ObligationCompletedResult: Decodable, Sendable, Equatable {
    public let obligationId: UUID
    public let status: String
    public let completedBy: UUID?
    public let completedAt: Date?
    public let alreadyCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case obligationId = "obligation_id"
        case status
        case completedBy = "completed_by"
        case completedAt = "completed_at"
        case alreadyCompleted = "already_completed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.obligationId = try c.decode(UUID.self, forKey: .obligationId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "completed"
        self.completedBy = try c.decodeIfPresent(UUID.self, forKey: .completedBy)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.alreadyCompleted = try c.decodeIfPresent(Bool.self, forKey: .alreadyCompleted) ?? false
    }

    public init(
        obligationId: UUID,
        status: String = "completed",
        completedBy: UUID? = nil,
        completedAt: Date? = nil,
        alreadyCompleted: Bool = false
    ) {
        self.obligationId = obligationId
        self.status = status
        self.completedBy = completedBy
        self.completedAt = completedAt
        self.alreadyCompleted = alreadyCompleted
    }
}

/// R.7.x — resultado de `forgive_obligation(p_obligation_id, p_reason?)`.
/// Backend retorna `{changed, obligation_id?, status, via_governance?, governance_action_id?, noop?}`.
/// `viaGovernance == true` cuando la acción se ejecutó porque una decisión la aprobó.
public struct ObligationForgivenResult: Decodable, Sendable, Equatable {
    public let changed: Bool
    public let obligationId: UUID?
    public let status: String
    public let viaGovernance: Bool
    public let governanceActionId: UUID?
    public let noop: Bool

    enum CodingKeys: String, CodingKey {
        case changed
        case obligationId = "obligation_id"
        case status
        case viaGovernance = "via_governance"
        case governanceActionId = "governance_action_id"
        case noop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? false
        self.obligationId = try c.decodeIfPresent(UUID.self, forKey: .obligationId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "forgiven"
        self.viaGovernance = try c.decodeIfPresent(Bool.self, forKey: .viaGovernance) ?? false
        self.governanceActionId = try c.decodeIfPresent(UUID.self, forKey: .governanceActionId)
        self.noop = try c.decodeIfPresent(Bool.self, forKey: .noop) ?? false
    }

    public init(
        changed: Bool,
        obligationId: UUID? = nil,
        status: String = "forgiven",
        viaGovernance: Bool = false,
        governanceActionId: UUID? = nil,
        noop: Bool = false
    ) {
        self.changed = changed
        self.obligationId = obligationId
        self.status = status
        self.viaGovernance = viaGovernance
        self.governanceActionId = governanceActionId
        self.noop = noop
    }
}

// MARK: - R.9.C Event weighted split (backend = autoridad)

/// Un renglón del preview ponderado (`preview_event_split().splits[]`).
public struct EventSplitShare: Decodable, Sendable, Equatable, Identifiable {
    public let actorId: UUID
    /// 1 + plus_count + guest shares vivos invitados por ese actor.
    public let weight: Int
    public let amount: Double

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case weight
        case amount
    }

    public init(actorId: UUID, weight: Int, amount: Double) {
        self.actorId = actorId
        self.weight = weight
        self.amount = amount
    }

    public var id: UUID { actorId }
}

/// Resultado de `preview_event_split(p_event_id, p_amount, p_currency)` (R.9.C).
/// Mismo cómputo + redondeo determinista que
/// `record_expense(split_basis='event_weights')`: iOS solo lo muestra.
public struct EventSplitPreview: Decodable, Sendable, Equatable {
    public let eventId: UUID
    public let amount: Double
    public let currency: String
    public let totalWeight: Int
    public let splits: [EventSplitShare]

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case amount
        case currency
        case totalWeight = "total_weight"
        case splits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.eventId = try c.decode(UUID.self, forKey: .eventId)
        self.amount = try c.decode(Double.self, forKey: .amount)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "MXN"
        self.totalWeight = try c.decodeIfPresent(Int.self, forKey: .totalWeight) ?? 0
        self.splits = try c.decodeIfPresent([EventSplitShare].self, forKey: .splits) ?? []
    }

    public init(eventId: UUID, amount: Double, currency: String, totalWeight: Int, splits: [EventSplitShare]) {
        self.eventId = eventId
        self.amount = amount
        self.currency = currency
        self.totalWeight = totalWeight
        self.splits = splits
    }

    public func share(for actorId: UUID) -> EventSplitShare? {
        splits.first { $0.actorId == actorId }
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
    /// R.5Z.fix.SETTLEMENT.HANDSHAKE — incluye `marked_paid_at/by`, `confirmed_at/by`,
    /// `rejected_at/by/reason`, `appealed_at/by/reason`. iOS usa estos campos para
    /// mostrar la historia del item (e.g., "fue reportado, apelá si insistís").
    public let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case settlementBatchId = "settlement_batch_id"
        case fromActorId = "from_actor_id"
        case toActorId = "to_actor_id"
        case amount
        case currency
        case status
        case metadata
    }

    public init(
        id: UUID,
        settlementBatchId: UUID,
        fromActorId: UUID,
        toActorId: UUID,
        amount: Double,
        currency: String,
        status: String = "pending",
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.settlementBatchId = settlementBatchId
        self.fromActorId = fromActorId
        self.toActorId = toActorId
        self.amount = amount
        self.currency = currency
        self.status = status
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.settlementBatchId = try c.decode(UUID.self, forKey: .settlementBatchId)
        self.fromActorId = try c.decode(UUID.self, forKey: .fromActorId)
        self.toActorId = try c.decode(UUID.self, forKey: .toActorId)
        self.amount = try c.decode(Double.self, forKey: .amount)
        self.currency = try c.decode(String.self, forKey: .currency)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }

    public var isPaid: Bool { status == "paid" }
    /// R.5Z.fix.SETTLEMENT.HANDSHAKE — el debtor marcó pagado pero el creditor
    /// aún no confirma. Se muestra como "Esperando confirmación".
    public var isPendingConfirmation: Bool { status == "pending_confirmation" }
    public var isPending: Bool { status == "pending" }
    /// R.5Z.fix.SETTLEMENT.APPEAL — debtor apeló el rechazo del creditor.
    /// Solo admin con money.settle puede resolver.
    public var isDisputed: Bool { status == "disputed" }
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

    /// `"$1,300"` — formato compacto sin centavos para chips, métricas y héroes.
    /// Usa `NumberFormatter` con el código ISO de la moneda (símbolo según locale).
    func compactCurrencyLabel(_ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: self)) ?? "\(Int(self)) \(currency)"
    }
}
