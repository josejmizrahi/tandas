import Foundation

// MARK: - Pools (R.8 — pool primitive)

/// Totales derivados de un pool (`list_context_pools().totals` /
/// `pool_account_detail().totals`).
public struct PoolTotals: Decodable, Sendable, Equatable {
    public let basisTotal: Double
    public let myBasis: Double
    public let contributorCount: Int
    public let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case basisTotal = "basis_total"
        case myBasis = "my_basis"
        case contributorCount = "contributor_count"
        case entryCount = "entry_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.basisTotal = try c.decodeIfPresent(Double.self, forKey: .basisTotal) ?? 0
        self.myBasis = try c.decodeIfPresent(Double.self, forKey: .myBasis) ?? 0
        self.contributorCount = try c.decodeIfPresent(Int.self, forKey: .contributorCount) ?? 0
        self.entryCount = try c.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
    }

    public init(basisTotal: Double, myBasis: Double = 0, contributorCount: Int = 0, entryCount: Int = 0) {
        self.basisTotal = basisTotal
        self.myBasis = myBasis
        self.contributorCount = contributorCount
        self.entryCount = entryCount
    }
}

/// Un pool del contexto. Forma wire de `list_context_pools()` (incluye `totals`)
/// y de `pool_account_detail().pool_account` (incluye `parent_context_actor_id`,
/// `created_by_actor_id`, `updated_at` — sin `totals`). Los campos que solo
/// existen en una de las dos formas son opcionales.
public struct PoolAccount: Decodable, Sendable, Equatable, Identifiable {
    public let poolAccountId: UUID
    public let poolActorId: UUID
    public let parentContextActorId: UUID?
    /// `winner_takes_all` | `equity_target` | `proportional` | `equal_share`
    /// | `rotational` | `custom_spec`. MVP UI: solo las dos primeras.
    public let policyKey: String
    public let policyConfig: JSONValue?
    /// `open` | `target_reached` | `resolving` | `resolved` | `cancelled`.
    public let status: String
    public let displayName: String
    public let description: String?
    public let currency: String?
    public let targetAmount: Double?
    public let createdByActorId: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let resolvedAt: Date?
    /// R.16.B — `pool_accounts.metadata` (jsonb libre; `source_event_id` liga
    /// el bote con el evento desde el que se creó). Solo lo expone
    /// `list_context_pools()` post-R.16.B; en shapes viejos viene nil.
    public let metadata: JSONValue?
    /// Solo en `list_context_pools()`.
    public let totals: PoolTotals?

    enum CodingKeys: String, CodingKey {
        case poolAccountId = "pool_account_id"
        case poolActorId = "pool_actor_id"
        case parentContextActorId = "parent_context_actor_id"
        case policyKey = "policy_key"
        case policyConfig = "policy_config"
        case status
        case displayName = "display_name"
        case description
        case currency
        case targetAmount = "target_amount"
        case createdByActorId = "created_by_actor_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
        case metadata
        case totals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.poolAccountId = try c.decode(UUID.self, forKey: .poolAccountId)
        self.poolActorId = try c.decode(UUID.self, forKey: .poolActorId)
        self.parentContextActorId = try c.decodeIfPresent(UUID.self, forKey: .parentContextActorId)
        self.policyKey = try c.decode(String.self, forKey: .policyKey)
        self.policyConfig = try c.decodeIfPresent(JSONValue.self, forKey: .policyConfig)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.targetAmount = try c.decodeIfPresent(Double.self, forKey: .targetAmount)
        self.createdByActorId = try c.decodeIfPresent(UUID.self, forKey: .createdByActorId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        self.totals = try c.decodeIfPresent(PoolTotals.self, forKey: .totals)
    }

    public init(
        poolAccountId: UUID,
        poolActorId: UUID,
        parentContextActorId: UUID? = nil,
        policyKey: String,
        policyConfig: JSONValue? = nil,
        status: String = "open",
        displayName: String,
        description: String? = nil,
        currency: String? = nil,
        targetAmount: Double? = nil,
        createdByActorId: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        resolvedAt: Date? = nil,
        metadata: JSONValue? = nil,
        totals: PoolTotals? = nil
    ) {
        self.poolAccountId = poolAccountId
        self.poolActorId = poolActorId
        self.parentContextActorId = parentContextActorId
        self.policyKey = policyKey
        self.policyConfig = policyConfig
        self.status = status
        self.displayName = displayName
        self.description = description
        self.currency = currency
        self.targetAmount = targetAmount
        self.createdByActorId = createdByActorId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.metadata = metadata
        self.totals = totals
    }

    public var id: UUID { poolAccountId }

    /// R.16.B — evento origen del bote (`metadata.source_event_id`). Se setea
    /// al crear el bote desde el detalle de un evento (viaje ↔ bote).
    public var sourceEventId: UUID? {
        metadata?["source_event_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    public var isOpen: Bool { status == "open" }
    public var isResolved: Bool { status == "resolved" }

    /// Naming user-facing firmado: winner_takes_all → "Bote",
    /// equity_target → "Fondo con meta".
    public var policyLabel: String {
        switch policyKey {
        case "winner_takes_all": return "Bote"
        case "equity_target": return "Fondo con meta"
        case "proportional": return "Fondo proporcional"
        case "equal_share": return "Fondo en partes iguales"
        case "rotational": return "Tanda"
        default: return "Fondo"
        }
    }

    public var statusLabel: String {
        switch status {
        case "open": return "Abierto"
        case "target_reached": return "Meta alcanzada"
        case "resolving": return "Resolviendo"
        case "resolved": return "Resuelto"
        case "cancelled": return "Cancelado"
        default: return status
        }
    }

    /// Copia con campos actualizados (para el Mock in-memory; los campos son `let`).
    public func updating(
        status: String? = nil,
        resolvedAt: Date? = nil,
        totals: PoolTotals? = nil
    ) -> PoolAccount {
        PoolAccount(
            poolAccountId: poolAccountId,
            poolActorId: poolActorId,
            parentContextActorId: parentContextActorId,
            policyKey: policyKey,
            policyConfig: policyConfig,
            status: status ?? self.status,
            displayName: displayName,
            description: description,
            currency: currency,
            targetAmount: targetAmount,
            createdByActorId: createdByActorId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            resolvedAt: resolvedAt ?? self.resolvedAt,
            metadata: metadata,
            totals: totals ?? self.totals
        )
    }
}

/// Una línea del basis ledger (`pool_account_detail().basis_entries[]`).
public struct PoolBasisEntry: Decodable, Sendable, Equatable, Identifiable {
    public let basisEntryId: UUID
    public let contributorActorId: UUID
    public let contributorDisplayName: String?
    /// `cash` | `asset` | `service` | `pending_stake`.
    public let basisKind: String
    public let basisAmount: Double
    public let currency: String?
    public let assetResourceId: UUID?
    public let assetDisplayName: String?
    public let valuationMethod: String?
    public let valuationNotes: String?
    public let pairedObligationId: UUID?
    public let moneyTransactionId: UUID?
    public let createdAt: Date?
    public let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case basisEntryId = "basis_entry_id"
        case contributorActorId = "contributor_actor_id"
        case contributorDisplayName = "contributor_display_name"
        case basisKind = "basis_kind"
        case basisAmount = "basis_amount"
        case currency
        case assetResourceId = "asset_resource_id"
        case assetDisplayName = "asset_display_name"
        case valuationMethod = "valuation_method"
        case valuationNotes = "valuation_notes"
        case pairedObligationId = "paired_obligation_id"
        case moneyTransactionId = "money_transaction_id"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.basisEntryId = try c.decode(UUID.self, forKey: .basisEntryId)
        self.contributorActorId = try c.decode(UUID.self, forKey: .contributorActorId)
        self.contributorDisplayName = try c.decodeIfPresent(String.self, forKey: .contributorDisplayName)
        self.basisKind = try c.decodeIfPresent(String.self, forKey: .basisKind) ?? "cash"
        self.basisAmount = try c.decodeIfPresent(Double.self, forKey: .basisAmount) ?? 0
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.assetResourceId = try c.decodeIfPresent(UUID.self, forKey: .assetResourceId)
        self.assetDisplayName = try c.decodeIfPresent(String.self, forKey: .assetDisplayName)
        self.valuationMethod = try c.decodeIfPresent(String.self, forKey: .valuationMethod)
        self.valuationNotes = try c.decodeIfPresent(String.self, forKey: .valuationNotes)
        self.pairedObligationId = try c.decodeIfPresent(UUID.self, forKey: .pairedObligationId)
        self.moneyTransactionId = try c.decodeIfPresent(UUID.self, forKey: .moneyTransactionId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }

    public init(
        basisEntryId: UUID,
        contributorActorId: UUID,
        contributorDisplayName: String? = nil,
        basisKind: String = "cash",
        basisAmount: Double,
        currency: String? = nil,
        assetResourceId: UUID? = nil,
        assetDisplayName: String? = nil,
        valuationMethod: String? = nil,
        valuationNotes: String? = nil,
        pairedObligationId: UUID? = nil,
        moneyTransactionId: UUID? = nil,
        createdAt: Date? = nil,
        resolvedAt: Date? = nil
    ) {
        self.basisEntryId = basisEntryId
        self.contributorActorId = contributorActorId
        self.contributorDisplayName = contributorDisplayName
        self.basisKind = basisKind
        self.basisAmount = basisAmount
        self.currency = currency
        self.assetResourceId = assetResourceId
        self.assetDisplayName = assetDisplayName
        self.valuationMethod = valuationMethod
        self.valuationNotes = valuationNotes
        self.pairedObligationId = pairedObligationId
        self.moneyTransactionId = moneyTransactionId
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    public var id: UUID { basisEntryId }

    public var basisKindLabel: String {
        switch basisKind {
        case "cash": return "Efectivo"
        case "asset": return "Activo"
        case "service": return "Servicio"
        case "pending_stake": return "Apuesta pendiente"
        default: return basisKind
        }
    }
}

/// `pool_account_detail(p_pool_account_id)` — pool + basis ledger + totals +
/// `available_actions` canónicos R.8 (pool.contribute / pool.resolve /
/// pool.cancel / pool.update_config).
public struct PoolAccountDetail: Decodable, Sendable, Equatable {
    public let poolAccount: PoolAccount
    public let basisEntries: [PoolBasisEntry]
    public let totals: PoolTotals
    public let availableActions: [AvailableAction]

    enum CodingKeys: String, CodingKey {
        case poolAccount = "pool_account"
        case basisEntries = "basis_entries"
        case totals
        case availableActions = "available_actions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.poolAccount = try c.decode(PoolAccount.self, forKey: .poolAccount)
        self.basisEntries = try c.decodeIfPresent([PoolBasisEntry].self, forKey: .basisEntries) ?? []
        self.totals = try c.decodeIfPresent(PoolTotals.self, forKey: .totals) ?? PoolTotals(basisTotal: 0)
        self.availableActions = try c.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
    }

    public init(
        poolAccount: PoolAccount,
        basisEntries: [PoolBasisEntry] = [],
        totals: PoolTotals = PoolTotals(basisTotal: 0),
        availableActions: [AvailableAction] = []
    ) {
        self.poolAccount = poolAccount
        self.basisEntries = basisEntries
        self.totals = totals
        self.availableActions = availableActions
    }

    public func can(_ key: String) -> Bool { availableActions.can(key) }
    public func action(_ key: String) -> AvailableAction? { availableActions.enabled(key) }
}

/// Un contribuyente con su share proporcional
/// (`preview_pool_resolution().contributors[]`).
public struct PoolResolutionContributor: Decodable, Sendable, Equatable, Identifiable {
    public let actorId: UUID
    public let displayName: String?
    public let basisAmount: Double
    /// Proporción basis/total ∈ [0, 1] (round(…, 6) en el wire).
    public let share: Double

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case displayName = "display_name"
        case basisAmount = "basis_amount"
        case share
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.basisAmount = try c.decodeIfPresent(Double.self, forKey: .basisAmount) ?? 0
        self.share = try c.decodeIfPresent(Double.self, forKey: .share) ?? 0
    }

    public init(actorId: UUID, displayName: String? = nil, basisAmount: Double, share: Double) {
        self.actorId = actorId
        self.displayName = displayName
        self.basisAmount = basisAmount
        self.share = share
    }

    public var id: UUID { actorId }
}

/// `preview_pool_resolution(p_pool_account_id)` — R.8.C. Read-only.
/// Campos comunes + extras por política: winner_takes_all trae
/// cash/stake/payout + `winnerKnown=false`; equity_target trae
/// target/progreso.
public struct PoolResolutionPreview: Decodable, Sendable, Equatable {
    public let poolAccountId: UUID
    public let policyKey: String
    public let resolutionKind: String
    public let status: String
    public let totalBasis: Double
    public let currency: String?
    public let entryCount: Int
    public let contributors: [PoolResolutionContributor]
    public let warnings: [String]
    // winner_takes_all
    public let cashTotal: Double?
    public let stakeTotal: Double?
    public let payoutAmount: Double?
    public let payoutCurrency: String?
    public let winnerKnown: Bool?
    // equity_target
    public let targetAmount: Double?
    public let targetReached: Bool?
    public let targetProgress: Double?
    public let remainingToTarget: Double?

    enum CodingKeys: String, CodingKey {
        case poolAccountId = "pool_account_id"
        case policyKey = "policy_key"
        case resolutionKind = "resolution_kind"
        case status
        case totalBasis = "total_basis"
        case currency
        case entryCount = "entry_count"
        case contributors
        case warnings
        case cashTotal = "cash_total"
        case stakeTotal = "stake_total"
        case payoutAmount = "payout_amount"
        case payoutCurrency = "payout_currency"
        case winnerKnown = "winner_known"
        case targetAmount = "target_amount"
        case targetReached = "target_reached"
        case targetProgress = "target_progress"
        case remainingToTarget = "remaining_to_target"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.poolAccountId = try c.decode(UUID.self, forKey: .poolAccountId)
        self.policyKey = try c.decode(String.self, forKey: .policyKey)
        self.resolutionKind = try c.decodeIfPresent(String.self, forKey: .resolutionKind) ?? self.policyKey
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.totalBasis = try c.decodeIfPresent(Double.self, forKey: .totalBasis) ?? 0
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.entryCount = try c.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        self.contributors = try c.decodeIfPresent([PoolResolutionContributor].self, forKey: .contributors) ?? []
        self.warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.cashTotal = try c.decodeIfPresent(Double.self, forKey: .cashTotal)
        self.stakeTotal = try c.decodeIfPresent(Double.self, forKey: .stakeTotal)
        self.payoutAmount = try c.decodeIfPresent(Double.self, forKey: .payoutAmount)
        self.payoutCurrency = try c.decodeIfPresent(String.self, forKey: .payoutCurrency)
        self.winnerKnown = try c.decodeIfPresent(Bool.self, forKey: .winnerKnown)
        self.targetAmount = try c.decodeIfPresent(Double.self, forKey: .targetAmount)
        self.targetReached = try c.decodeIfPresent(Bool.self, forKey: .targetReached)
        self.targetProgress = try c.decodeIfPresent(Double.self, forKey: .targetProgress)
        self.remainingToTarget = try c.decodeIfPresent(Double.self, forKey: .remainingToTarget)
    }

    public init(
        poolAccountId: UUID,
        policyKey: String,
        resolutionKind: String? = nil,
        status: String = "open",
        totalBasis: Double,
        currency: String? = nil,
        entryCount: Int,
        contributors: [PoolResolutionContributor] = [],
        warnings: [String] = [],
        cashTotal: Double? = nil,
        stakeTotal: Double? = nil,
        payoutAmount: Double? = nil,
        payoutCurrency: String? = nil,
        winnerKnown: Bool? = nil,
        targetAmount: Double? = nil,
        targetReached: Bool? = nil,
        targetProgress: Double? = nil,
        remainingToTarget: Double? = nil
    ) {
        self.poolAccountId = poolAccountId
        self.policyKey = policyKey
        self.resolutionKind = resolutionKind ?? policyKey
        self.status = status
        self.totalBasis = totalBasis
        self.currency = currency
        self.entryCount = entryCount
        self.contributors = contributors
        self.warnings = warnings
        self.cashTotal = cashTotal
        self.stakeTotal = stakeTotal
        self.payoutAmount = payoutAmount
        self.payoutCurrency = payoutCurrency
        self.winnerKnown = winnerKnown
        self.targetAmount = targetAmount
        self.targetReached = targetReached
        self.targetProgress = targetProgress
        self.remainingToTarget = remainingToTarget
    }

    /// `true` si el preview indica que la resolución puede proceder.
    public var isResolvable: Bool {
        (status == "open" || status == "target_reached") && entryCount > 0
    }
}

/// Resultado de `create_pool()`.
public struct PoolCreated: Decodable, Sendable, Equatable {
    public let poolAccountId: UUID
    public let poolActorId: UUID
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case poolAccountId = "pool_account_id"
        case poolActorId = "pool_actor_id"
        case idempotentReplay = "idempotent_replay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.poolAccountId = try c.decode(UUID.self, forKey: .poolAccountId)
        self.poolActorId = try c.decode(UUID.self, forKey: .poolActorId)
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }

    public init(poolAccountId: UUID, poolActorId: UUID, idempotentReplay: Bool = false) {
        self.poolAccountId = poolAccountId
        self.poolActorId = poolActorId
        self.idempotentReplay = idempotentReplay
    }
}

/// Resultado de `contribute_to_pool()`.
public struct PoolContributionResult: Decodable, Sendable, Equatable {
    public let basisEntryId: UUID
    public let pairedObligationId: UUID?
    public let moneyTransactionId: UUID?
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case basisEntryId = "basis_entry_id"
        case pairedObligationId = "paired_obligation_id"
        case moneyTransactionId = "money_transaction_id"
        case idempotentReplay = "idempotent_replay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.basisEntryId = try c.decode(UUID.self, forKey: .basisEntryId)
        self.pairedObligationId = try c.decodeIfPresent(UUID.self, forKey: .pairedObligationId)
        self.moneyTransactionId = try c.decodeIfPresent(UUID.self, forKey: .moneyTransactionId)
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }

    public init(
        basisEntryId: UUID,
        pairedObligationId: UUID? = nil,
        moneyTransactionId: UUID? = nil,
        idempotentReplay: Bool = false
    ) {
        self.basisEntryId = basisEntryId
        self.pairedObligationId = pairedObligationId
        self.moneyTransactionId = moneyTransactionId
        self.idempotentReplay = idempotentReplay
    }
}

/// Resultado de `resolve_pool()` — la forma varía por política; los campos
/// específicos son opcionales. `alreadyResolved=true` cuando el pool ya
/// estaba resuelto (espejo de execute_decision.already_executed).
public struct PoolResolutionResult: Decodable, Sendable, Equatable {
    public let poolAccountId: UUID
    public let status: String
    public let policyKey: String?
    // winner_takes_all
    public let winnerActorId: UUID?
    public let payoutTransactionId: UUID?
    public let payoutAmount: Double?
    public let payoutCurrency: String?
    // equity_target
    public let totalBasis: Double?
    public let targetReached: Bool?
    public let settledObligationCount: Int?
    public let alreadyResolved: Bool
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case poolAccountId = "pool_account_id"
        case status
        case policyKey = "policy_key"
        case winnerActorId = "winner_actor_id"
        case payoutTransactionId = "payout_transaction_id"
        case payoutAmount = "payout_amount"
        case payoutCurrency = "payout_currency"
        case totalBasis = "total_basis"
        case targetReached = "target_reached"
        case settledObligationCount = "settled_obligation_count"
        case alreadyResolved = "already_resolved"
        case idempotentReplay = "idempotent_replay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.poolAccountId = try c.decode(UUID.self, forKey: .poolAccountId)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "resolved"
        self.policyKey = try c.decodeIfPresent(String.self, forKey: .policyKey)
        self.winnerActorId = try c.decodeIfPresent(UUID.self, forKey: .winnerActorId)
        self.payoutTransactionId = try c.decodeIfPresent(UUID.self, forKey: .payoutTransactionId)
        self.payoutAmount = try c.decodeIfPresent(Double.self, forKey: .payoutAmount)
        self.payoutCurrency = try c.decodeIfPresent(String.self, forKey: .payoutCurrency)
        self.totalBasis = try c.decodeIfPresent(Double.self, forKey: .totalBasis)
        self.targetReached = try c.decodeIfPresent(Bool.self, forKey: .targetReached)
        self.settledObligationCount = try c.decodeIfPresent(Int.self, forKey: .settledObligationCount)
        self.alreadyResolved = try c.decodeIfPresent(Bool.self, forKey: .alreadyResolved) ?? false
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }

    public init(
        poolAccountId: UUID,
        status: String = "resolved",
        policyKey: String? = nil,
        winnerActorId: UUID? = nil,
        payoutTransactionId: UUID? = nil,
        payoutAmount: Double? = nil,
        payoutCurrency: String? = nil,
        totalBasis: Double? = nil,
        targetReached: Bool? = nil,
        settledObligationCount: Int? = nil,
        alreadyResolved: Bool = false,
        idempotentReplay: Bool = false
    ) {
        self.poolAccountId = poolAccountId
        self.status = status
        self.policyKey = policyKey
        self.winnerActorId = winnerActorId
        self.payoutTransactionId = payoutTransactionId
        self.payoutAmount = payoutAmount
        self.payoutCurrency = payoutCurrency
        self.totalBasis = totalBasis
        self.targetReached = targetReached
        self.settledObligationCount = settledObligationCount
        self.alreadyResolved = alreadyResolved
        self.idempotentReplay = idempotentReplay
    }
}
