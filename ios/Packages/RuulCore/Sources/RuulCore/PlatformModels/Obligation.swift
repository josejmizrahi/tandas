import Foundation

/// Money 2.0 obligation — owed money that exists as a first-class entity
/// (not derived implicitly from `ledger_entries`).
///
/// Three flavors today, distinguished by `kind`:
///   - `.peer` (Phase 4.1, mig 20260526000000): one member owes another,
///     materialized from `expense` ledger entries with `split_breakdown`.
///   - `.fine` (Phase 4.3, mig 20260526030000): one member owes the
///     group/pool as a punitive consequence of breaking a rule.
///   - `.poolCharge` (Phase 4.4, mig 20260526040000): one member owes the
///     group/pool an expected contribution (cuota, poker buy-in, tanda).
///     NOT punitive — just a scheduled or batch-issued debt.
///
/// `owed_to_member_id` is nil for `.fine` and `.poolCharge` (NULL means
/// "owed to the group/pool"). It's non-nil for `.peer`.
///
/// Lifecycle
/// =========
///   - `.peer`     created → settles via `record_settlement_v2` (FIFO
///                 against open dyad obligations).
///   - `.fine`     created → settles via `fine_paid` ledger atom which
///                 triggers `obligations.status='settled'`.
///   - `.poolCharge` created → settles via `pay_pool_charge` RPC which
///                 emits a `contribution` ledger entry AND closes the
///                 obligation atomically.
///
/// Status transitions advance the lifecycle — the row is never deleted.
/// Errors → `void` + create correction.
public struct Obligation: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let groupId: UUID
    /// FK to `ledger_entries.id` (the expense or fine atom that created
    /// this obligation). NULL for pool charges (no source ledger atom —
    /// they're issued directly via RPC) and when the source ledger
    /// entry was deleted.
    public let sourceMovementId: UUID?
    public let owedByMemberId: UUID
    /// Peer creditor (group_members.id). **NULL means "owed to the
    /// group/pool"** — canonical for `.fine` and `.poolCharge`. Peer
    /// obligations always carry a non-NULL value.
    public let owedToMemberId: UUID?
    public let amountCents: Int64
    public let currency: String
    public let status: ObligationStatus
    /// FK to `resources.id` — event/asset/space the underlying movement
    /// was attributed to. Powers "Linda te debe $200 (de la cena del
    /// jueves)" sentences and per-resource breakdowns.
    public let sourceResourceId: UUID?
    /// Discriminator added in Phase 4.4 (mig 20260526040000). Defaults
    /// to `.peer` in the backend so historical rows backfill cleanly.
    public let kind: ObligationKind
    /// Stable idempotency key for batch-issued pool charges (Phase 4.4,
    /// mig 20260526040000). One client_id per `issue_pool_charges` call;
    /// every obligation in the batch shares the same key. NULL for
    /// peer/fine obligations created via other paths.
    public let clientId: UUID?
    /// Optional due date (Phase 4.4, mig 20260526040000). For pool
    /// charges: "Juan debe meter $500 antes del viernes". UI surfaces
    /// overdue cuotas distinctively when this is past `now()`.
    public let dueAt: Date?
    /// Source-specific payload. Common keys:
    ///   - `kind`        — mirror of the `kind` column (legacy/redundant)
    ///   - `reason`      — human reason (pool charge concept, fine label)
    ///   - `issued_by`   — auth.uid of the caller who created the row
    ///   - `fine_id`     — FK to `fines.id` when kind = .fine
    ///   - `rule_id`     — FK to `rules.id` when kind = .fine
    ///   - `voided_by`, `voided_reason` — set on void
    public let metadata: JSONConfig
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        groupId: UUID,
        sourceMovementId: UUID?,
        owedByMemberId: UUID,
        owedToMemberId: UUID?,
        amountCents: Int64,
        currency: String,
        status: ObligationStatus,
        sourceResourceId: UUID?,
        kind: ObligationKind = .peer,
        clientId: UUID? = nil,
        dueAt: Date? = nil,
        metadata: JSONConfig = .object([:]),
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.sourceMovementId = sourceMovementId
        self.owedByMemberId = owedByMemberId
        self.owedToMemberId = owedToMemberId
        self.amountCents = amountCents
        self.currency = currency
        self.status = status
        self.sourceResourceId = sourceResourceId
        self.kind = kind
        self.clientId = clientId
        self.dueAt = dueAt
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when this obligation represents a fine (owed to the group
    /// pool, not a specific peer). Phase 4.3 (mig 20260526030000).
    public var isFineObligation: Bool { kind == .fine }
    /// True when this obligation represents an expected contribution
    /// (cuota / buy-in). Phase 4.4 (mig 20260526040000).
    public var isPoolCharge: Bool { kind == .poolCharge }
    /// True when this obligation represents a peer-to-peer IOU.
    public var isPeerObligation: Bool { kind == .peer }
    /// True when the obligation flows toward the group/pool (vs a peer).
    public var isOwedToPool: Bool { owedToMemberId == nil }

    /// Free-text concept written by the issuer (pool charge reason,
    /// fine label). Reads from `metadata.reason`.
    public var reason: String? {
        guard case let .string(s) = metadata["reason"] ?? .null, !s.isEmpty else {
            return nil
        }
        return s
    }

    /// Past-due flag. Only meaningful when `dueAt != nil` and the
    /// obligation is still active.
    public var isOverdue: Bool {
        guard let due = dueAt, isActive else { return false }
        return due < .now
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId            = "group_id"
        case sourceMovementId   = "source_movement_id"
        case owedByMemberId     = "owed_by_member_id"
        case owedToMemberId     = "owed_to_member_id"
        case amountCents        = "amount_cents"
        case currency
        case status
        case sourceResourceId   = "source_resource_id"
        case kind
        case clientId           = "client_id"
        case dueAt              = "due_at"
        case metadata
        case createdAt          = "created_at"
        case updatedAt          = "updated_at"
    }

    /// True when the obligation is still actionable (owed money is
    /// still outstanding). Excludes fully settled / voided / disputed.
    public var isActive: Bool {
        switch status {
        case .open, .partiallyPaid, .paidPendingConfirmation:
            return true
        case .settled, .voided, .disputed:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id               = try c.decode(UUID.self, forKey: .id)
        self.groupId          = try c.decode(UUID.self, forKey: .groupId)
        self.sourceMovementId = try c.decodeIfPresent(UUID.self, forKey: .sourceMovementId)
        self.owedByMemberId   = try c.decode(UUID.self, forKey: .owedByMemberId)
        self.owedToMemberId   = try c.decodeIfPresent(UUID.self, forKey: .owedToMemberId)
        self.amountCents      = try Self.decodeCents(c, .amountCents)
        self.currency         = try c.decode(String.self, forKey: .currency)
        self.status           = try c.decode(ObligationStatus.self, forKey: .status)
        self.sourceResourceId = try c.decodeIfPresent(UUID.self, forKey: .sourceResourceId)
        // Tolerate older rows where `kind` was not yet stamped — backend
        // backfill set 'peer' as the default, but we mirror that here
        // so iOS preview fixtures and any cached responses still decode.
        self.kind             = try c.decodeIfPresent(ObligationKind.self, forKey: .kind) ?? .peer
        self.clientId         = try c.decodeIfPresent(UUID.self, forKey: .clientId)
        self.dueAt            = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        self.metadata         = try c.decodeIfPresent(JSONConfig.self, forKey: .metadata) ?? .object([:])
        self.createdAt        = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt        = try c.decode(Date.self, forKey: .updatedAt)
    }

    private static func decodeCents(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Int64 {
        if let int64 = try? c.decode(Int64.self, forKey: key) { return int64 }
        if let int = try? c.decode(Int.self, forKey: key) { return Int64(int) }
        if let str = try? c.decode(String.self, forKey: key),
           let int64 = Int64(str) { return int64 }
        return try c.decode(Int64.self, forKey: key)
    }
}

public enum ObligationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case peer
    case fine
    case poolCharge = "pool_charge"

    public var displayLabel: String {
        switch self {
        case .peer:        return "Entre miembros"
        case .fine:        return "Multa"
        case .poolCharge:  return "Cuota al pool"
        }
    }
}

public enum ObligationStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case open
    case partiallyPaid               = "partially_paid"
    case paidPendingConfirmation     = "paid_pending_confirmation"
    case settled
    case disputed
    case voided

    public var displayLabel: String {
        switch self {
        case .open:                       return "Pendiente"
        case .partiallyPaid:              return "Pagada parcialmente"
        case .paidPendingConfirmation:    return "Esperando confirmación"
        case .settled:                    return "Liquidada"
        case .disputed:                   return "En disputa"
        case .voided:                     return "Anulada"
        }
    }
}
