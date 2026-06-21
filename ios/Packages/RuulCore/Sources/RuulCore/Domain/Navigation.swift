import Foundation

// MARK: - AttentionItem

/// F.NAV.0 — Item del `attention_inbox()` cross-context. Shape canónico:
/// {kind, subject_id, context_actor_id, context_display_name, title, reason,
///  cta_action_key, cta_scope_kind, cta_scope_id, occurred_at}.
///
/// El `cta_action_key` es compatible con `ActionRouter` (F.2X). Cada
/// `cta_scope_kind` mapea a un `ActionScope` (`reservation`/`decision`/
/// `obligation`/`context`).
public struct AttentionItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let kind: String
    public let subjectId: UUID
    public let contextActorId: UUID
    public let contextDisplayName: String
    public let title: String
    public let reason: String
    public let ctaActionKey: String
    public let ctaScopeKind: String
    public let ctaScopeId: UUID
    public let occurredAt: Date?

    // R.5Y.A1.1 — settlement_open enrichment: monto/moneda/contraparte top-level.
    public let amount: Decimal?
    public let currency: String?
    public let counterpartyName: String?

    // R.5Y.A1.2 — reservation_conflict + resource_conflict_direct emiten resource_id
    // top-level para que el dispatcher pueda cargar la vista de detalle del recurso.
    public let resourceId: UUID?

    enum CodingKeys: String, CodingKey {
        case kind
        case subjectId = "subject_id"
        case contextActorId = "context_actor_id"
        case contextDisplayName = "context_display_name"
        case title
        case reason
        case ctaActionKey = "cta_action_key"
        case ctaScopeKind = "cta_scope_kind"
        case ctaScopeId = "cta_scope_id"
        case occurredAt = "occurred_at"
        case amount
        case currency
        case counterpartyName = "counterparty_name"
        case resourceId = "resource_id"
    }

    public init(
        kind: String,
        subjectId: UUID,
        contextActorId: UUID,
        contextDisplayName: String,
        title: String,
        reason: String,
        ctaActionKey: String,
        ctaScopeKind: String,
        ctaScopeId: UUID,
        occurredAt: Date? = nil,
        amount: Decimal? = nil,
        currency: String? = nil,
        counterpartyName: String? = nil,
        resourceId: UUID? = nil
    ) {
        self.kind = kind
        self.subjectId = subjectId
        self.contextActorId = contextActorId
        self.contextDisplayName = contextDisplayName
        self.title = title
        self.reason = reason
        self.ctaActionKey = ctaActionKey
        self.ctaScopeKind = ctaScopeKind
        self.ctaScopeId = ctaScopeId
        self.occurredAt = occurredAt
        self.amount = amount
        self.currency = currency
        self.counterpartyName = counterpartyName
        self.resourceId = resourceId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.subjectId = try c.decode(UUID.self, forKey: .subjectId)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.contextDisplayName = try c.decode(String.self, forKey: .contextDisplayName)
        self.title = try c.decode(String.self, forKey: .title)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.ctaActionKey = try c.decode(String.self, forKey: .ctaActionKey)
        self.ctaScopeKind = try c.decode(String.self, forKey: .ctaScopeKind)
        self.ctaScopeId = try c.decode(UUID.self, forKey: .ctaScopeId)
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        self.amount = try c.decodeIfPresent(Decimal.self, forKey: .amount)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.counterpartyName = try c.decodeIfPresent(String.self, forKey: .counterpartyName)
        self.resourceId = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
    }

    public var id: UUID { subjectId }
}

// MARK: - AttentionPriority

/// R.5Y.A2 — Prioridad derivada por kind para sorting/visual emphasis.
/// Por ahora computada client-side; futuro backend puede emitir `priority`
/// explícito en el item.
public enum AttentionPriority: Int, Sendable, Comparable {
    case critical = 0
    case high = 1
    case normal = 2
    case low = 3

    public static func < (lhs: AttentionPriority, rhs: AttentionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension AttentionItem {
    /// R.5Y.A2 — Prioridad derivada por kind. Heurística single-source:
    /// conflicts → critical · pagos/decisiones/compromisos → high · invitaciones → normal.
    public var derivedPriority: AttentionPriority {
        switch kind {
        case "reservation_conflict", "resource_conflict_direct":
            return .critical
        case "decision_vote", "obligation_pay", "obligation_complete", "settlement_open":
            return .high
        case "invitation":
            return .normal
        default:
            return .normal
        }
    }
}

// MARK: - ContextPreference

/// F.NAV.0 — Fila de `actor_context_preferences` unida a `actors`. Se entrega
/// desde `list_context_favorites()` y `list_recent_contexts()`.
public struct ContextPreference: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let contextActorId: UUID
    public let displayName: String
    public let actorKind: String
    public let actorSubtype: String?
    public let isFavorite: Bool
    public let favoritedAt: Date?
    public let lastVisitedAt: Date?

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case isFavorite = "is_favorite"
        case favoritedAt = "favorited_at"
        case lastVisitedAt = "last_visited_at"
    }

    public init(
        contextActorId: UUID,
        displayName: String,
        actorKind: String,
        actorSubtype: String? = nil,
        isFavorite: Bool = false,
        favoritedAt: Date? = nil,
        lastVisitedAt: Date? = nil
    ) {
        self.contextActorId = contextActorId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.isFavorite = isFavorite
        self.favoritedAt = favoritedAt
        self.lastVisitedAt = lastVisitedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.actorKind = try c.decode(String.self, forKey: .actorKind)
        self.actorSubtype = try c.decodeIfPresent(String.self, forKey: .actorSubtype)
        self.isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.favoritedAt = try c.decodeIfPresent(Date.self, forKey: .favoritedAt)
        self.lastVisitedAt = try c.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
    }

    public var id: UUID { contextActorId }
}

// MARK: - ContextOverview (R.11.E)

/// R.11.E — Fila de `home_overview()` RPC. Métricas vivas por contexto
/// para alimentar Home ("Hoy en tus espacios") y Contextos lista densa
/// con un solo round-trip al backend.
///
/// Shape canónico:
/// ```
/// {
///   context_actor_id, display_name, actor_kind, actor_subtype,
///   is_favorite, last_visited_at,
///   member_count, pending_count,
///   next_event_at, next_event_title,
///   my_balance, balance_currency
/// }
/// ```
///
/// `pending_count` agrega obligations(debtor=caller, open) + decisions
/// (open, sin voto del caller). `my_balance` es net en la moneda con
/// mayor `abs(net)` por contexto.
public struct ContextOverview: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let contextActorId: UUID
    public let displayName: String
    public let actorKind: String
    public let actorSubtype: String?
    public let isFavorite: Bool
    public let lastVisitedAt: Date?
    public let memberCount: Int
    public let pendingCount: Int
    public let nextEventAt: Date?
    public let nextEventTitle: String?
    public let myBalance: Double?
    public let balanceCurrency: String?
    /// R.14.B (2026-06-21) — agregados para friend-group launch P0 #3/#4.
    public let poolsTotal: Double?
    public let poolsCurrency: String?
    public let poolsCount: Int
    public let lastActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
        case actorSubtype = "actor_subtype"
        case isFavorite = "is_favorite"
        case lastVisitedAt = "last_visited_at"
        case memberCount = "member_count"
        case pendingCount = "pending_count"
        case nextEventAt = "next_event_at"
        case nextEventTitle = "next_event_title"
        case myBalance = "my_balance"
        case balanceCurrency = "balance_currency"
        case poolsTotal = "pools_total"
        case poolsCurrency = "pools_currency"
        case poolsCount = "pools_count"
        case lastActivityAt = "last_activity_at"
    }

    public init(
        contextActorId: UUID,
        displayName: String,
        actorKind: String,
        actorSubtype: String? = nil,
        isFavorite: Bool = false,
        lastVisitedAt: Date? = nil,
        memberCount: Int = 0,
        pendingCount: Int = 0,
        nextEventAt: Date? = nil,
        nextEventTitle: String? = nil,
        myBalance: Double? = nil,
        balanceCurrency: String? = nil,
        poolsTotal: Double? = nil,
        poolsCurrency: String? = nil,
        poolsCount: Int = 0,
        lastActivityAt: Date? = nil
    ) {
        self.contextActorId = contextActorId
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.isFavorite = isFavorite
        self.lastVisitedAt = lastVisitedAt
        self.memberCount = memberCount
        self.pendingCount = pendingCount
        self.nextEventAt = nextEventAt
        self.nextEventTitle = nextEventTitle
        self.myBalance = myBalance
        self.balanceCurrency = balanceCurrency
        self.poolsTotal = poolsTotal
        self.poolsCurrency = poolsCurrency
        self.poolsCount = poolsCount
        self.lastActivityAt = lastActivityAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.actorKind = try c.decode(String.self, forKey: .actorKind)
        self.actorSubtype = try c.decodeIfPresent(String.self, forKey: .actorSubtype)
        self.isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.lastVisitedAt = try c.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
        self.memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        self.pendingCount = try c.decodeIfPresent(Int.self, forKey: .pendingCount) ?? 0
        self.nextEventAt = try c.decodeIfPresent(Date.self, forKey: .nextEventAt)
        self.nextEventTitle = try c.decodeIfPresent(String.self, forKey: .nextEventTitle)
        self.myBalance = try c.decodeIfPresent(Double.self, forKey: .myBalance)
        self.balanceCurrency = try c.decodeIfPresent(String.self, forKey: .balanceCurrency)
        self.poolsTotal = try c.decodeIfPresent(Double.self, forKey: .poolsTotal)
        self.poolsCurrency = try c.decodeIfPresent(String.self, forKey: .poolsCurrency)
        self.poolsCount = try c.decodeIfPresent(Int.self, forKey: .poolsCount) ?? 0
        self.lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
    }

    public var id: UUID { contextActorId }

    /// `true` si tiene actividad relevante hoy/próximos días que merece
    /// surface en Home "Hoy en tus espacios": evento próximo, balance no
    /// cero, o pendientes.
    public func isActionableToday(now: Date = Date(), eventWindow: TimeInterval = 7 * 24 * 3600) -> Bool {
        if pendingCount > 0 { return true }
        if let amount = myBalance, amount != 0 { return true }
        if let date = nextEventAt, date >= now, date <= now.addingTimeInterval(eventWindow) {
            return true
        }
        return false
    }
}
