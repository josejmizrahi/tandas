import Foundation

/// Money 2.0 Phase 4.2 (mig 20260526010000 + 20260526010500):
/// canonical settlement entity. Closes (partial or total) obligations
/// via the `settlement_obligations` bridge table.
///
/// Founder doctrine 2026-05-25 (8-layer money architecture):
///   * Capa 4 (Settlements) — cómo se cierran obligations.
///   * Append-only en filosofía: la row no se borra. Status transitions
///     (`confirmed`, `rejected`, `disputed`, `cancelled`) avanzan el
///     lifecycle; la traza queda.
///   * Idempotente vía `(group_id, client_id)` partial unique index.
///   * Cada settlement enlaza con un `ledger_entries` audit row
///     (`ledgerEntryId`) que sigue siendo el source para balance views.
///
/// Bridge `settlement_obligations` (not modeled here directly — read on
/// demand): tells WHICH obligations were closed and BY HOW MUCH each.
/// FIFO-allocated by `record_settlement_v2` against open obligations
/// of the dyad (`owed_by=from`, `owed_to=to`).
///
/// Over-allocation semantics: si `amountCents` > total outstanding del
/// dyad, la diferencia queda unallocated (no bridge row). El balance
/// view igual refleja el monto completo como "advance / credit" hasta
/// que Phase 6 (Wallet) materialice eso formalmente.
public struct Settlement: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let groupId: UUID
    public let fromMemberId: UUID
    public let toMemberId: UUID
    public let amountCents: Int64
    public let currency: String
    public let status: SettlementStatus
    /// FK to `ledger_entries.id` — the audit row written by
    /// `record_settlement_v2` for balance projection. NULL only in
    /// transient mid-RPC state (should always be set on success).
    public let ledgerEntryId: UUID?
    /// FK to `resources.id` — event/asset/space the settlement was
    /// attributed to (e.g. "salda lo de esta cena").
    public let sourceResourceId: UUID?
    public let note: String?
    public let clientId: UUID?
    public let recordedBy: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String,
        status: SettlementStatus,
        ledgerEntryId: UUID?,
        sourceResourceId: UUID?,
        note: String?,
        clientId: UUID?,
        recordedBy: UUID?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.fromMemberId = fromMemberId
        self.toMemberId = toMemberId
        self.amountCents = amountCents
        self.currency = currency
        self.status = status
        self.ledgerEntryId = ledgerEntryId
        self.sourceResourceId = sourceResourceId
        self.note = note
        self.clientId = clientId
        self.recordedBy = recordedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId          = "group_id"
        case fromMemberId     = "from_member_id"
        case toMemberId       = "to_member_id"
        case amountCents      = "amount_cents"
        case currency
        case status
        case ledgerEntryId    = "ledger_entry_id"
        case sourceResourceId = "source_resource_id"
        case note
        case clientId         = "client_id"
        case recordedBy       = "recorded_by"
        case createdAt        = "created_at"
        case updatedAt        = "updated_at"
    }
}

public enum SettlementStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case initiated
    case confirmed
    case rejected
    case disputed
    case cancelled

    public var displayLabel: String {
        switch self {
        case .initiated:  return "Pendiente de confirmar"
        case .confirmed:  return "Confirmada"
        case .rejected:   return "Rechazada"
        case .disputed:   return "En disputa"
        case .cancelled:  return "Cancelada"
        }
    }
}
