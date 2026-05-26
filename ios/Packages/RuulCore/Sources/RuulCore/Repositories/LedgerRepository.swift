import Foundation
import Supabase

public enum LedgerError: Error, Equatable, LocalizedError {
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rpcFailed(let msg):
            return msg.isEmpty ? "RPC failed" : msg
        }
    }
}

/// Reads/writes for `public.ledger_entries` (atom log).
///
/// Ledger entries are append-only at the spec level. Callers SHOULD only
/// insert, never update. This repo intentionally exposes no update/delete
/// to enforce the invariant on the iOS side.
public protocol LedgerRepository: Actor {
    /// All ledger entries for a group, newest first. Used for the
    /// group-wide money feed.
    func list(groupId: UUID, limit: Int) async throws -> [LedgerEntry]
    /// Entries scoped to a specific resource (event, fund, booking).
    /// Powers the per-resource Money section.
    func listForResource(_ resourceId: UUID, limit: Int) async throws -> [LedgerEntry]
    /// Entries involving a specific member (either side).
    func listForMember(_ memberId: UUID, limit: Int) async throws -> [LedgerEntry]
    /// Records a new entry via direct INSERT. RLS gates by admin (mig 00078).
    /// Prefer `recordEntry(...)` which uses the `record_ledger_entry` RPC
    /// available to any group member (mig 00082).
    func record(_ entry: LedgerEntry) async throws -> LedgerEntry
    /// Records a money atom via the `record_ledger_entry` RPC (mig 00082).
    /// Any group member can call. When `resourceId` is set, the entry is
    /// scoped to that resource (event/fund/asset) per Taxonomy §29.
    func recordEntry(
        groupId: UUID,
        resourceId: UUID?,
        type: String,
        amountCents: Int64,
        fromMemberId: UUID?,
        toMemberId: UUID?,
        currency: String,
        metadata: JSONConfig
    ) async throws -> LedgerEntry

    /// Tier 6 final: records a one-tap settlement via the dedicated
    /// `record_settlement` RPC (mig 00145). Bilateral — both
    /// fromMemberId + toMemberId required, amount must be positive,
    /// both members must belong to the group. The balance projection
    /// views update automatically.
    func recordSettlement(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String,
        resourceId: UUID?,
        note: String?
    ) async throws -> LedgerEntry

    /// Money 2.0 Phase 4.2 (mig 20260526010500): canonical settlement
    /// writer. Creates a `settlements` row, FIFO-allocates against open
    /// obligations via `settlement_obligations` bridge, updates each
    /// touched obligation to `partially_paid` / `settled`, and writes
    /// the audit ledger entry (type='settlement') for balance views.
    /// Idempotent via `clientId`. Over-allocation allowed (excess shows
    /// as advance/credit in balance views until Phase 6 Wallet
    /// formalizes it).
    func recordSettlementV2(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        clientId: UUID,
        sourceResourceId: UUID?
    ) async throws -> Settlement

    /// SharedMoney P3: per-(member, currency) net positions in a group,
    /// derived from `member_balances_per_group` (mig 00136). Powers the
    /// "Tu posición" card on GroupSpaceView + the
    /// `GroupBalancesView` subscreen ("Te deben / Debes").
    func balancesForGroup(_ groupId: UUID) async throws -> [MemberGroupBalance]

    /// FASE 4 Wave 4 / Phase 5 foundation (mig 20260525230000):
    /// per (member, currency) breakdown of stake / receivable /
    /// obligation / settlement net via `member_obligations_view`.
    /// Replaces the naïve `balancesForGroup` for surfaces that need
    /// to distinguish capital injection from peer-relevant debt.
    /// Use `netPeerPositionCents` (NOT `MemberGroupBalance.netCents`)
    /// for greedy settlement plans.
    func obligationsForGroup(_ groupId: UUID) async throws -> [MemberObligationSummary]

    /// Money 2.0 Phase 4.1 (mig 20260526000000): per-pair peer
    /// obligations materialized from expenses with split_breakdown.
    /// Returns ALL obligations for the group (active and historical).
    /// Filter by `isActive` client-side for the surface that only
    /// shows outstanding ones.
    func obligationsTable(_ groupId: UUID) async throws -> [Obligation]

    /// FASE 4 Wave 4 Phase 3 Tier 2 (mig 20260525233000): canonical
    /// pool→member outflow for capital returns / dividendos / stipends.
    /// Writes a `payout` ledger entry (from=NULL, to=member). Distinct
    /// from `reimbursement` (cancels a fronted expense receivable —
    /// use `recordEntry(type='reimbursement', from=member, to=NULL)`).
    /// Idempotent via `clientId`.
    func recordPayout(
        groupId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String,
        note: String?,
        clientId: UUID
    ) async throws -> LedgerEntry

    /// SharedMoney P9: returns the viewer's own balance rows across
    /// every group in `groupIds`. Powers the cross-group obligations
    /// roll-up on the Home tab. Implementation walks
    /// `group_members` → `member_balances_per_group` filtered to the
    /// viewer's `user_id`. Returns only rows where the viewer is a
    /// member of the given group AND has non-zero history (the view
    /// only emits rows for members with at least one ledger entry).
    func myBalancesAcrossGroups(
        userId: UUID,
        groupIds: [UUID]
    ) async throws -> [MemberGroupBalance]

    /// Edit foundation (mig 00368): appends a settlement-shaped
    /// "undo" entry that neutralizes the original on every projection.
    /// Caller must be the original `recorded_by`. Idempotent via
    /// `clientId` (stamped into `metadata.client_id`). Returns the
    /// inserted reverse entry — callers should reload affected views.
    func reverseEntry(
        entryId: UUID,
        reason: String?,
        clientId: UUID
    ) async throws -> LedgerEntry

    /// Mig 00372: in-place edit of the entry's note field. The atom
    /// log stays immutable for math (amount/from/to/type) — only the
    /// descriptive note is mutable. Updates both `ledger_entries` and
    /// the originating `system_events.payload` so the activity feed
    /// reflects the new text on next refresh. Pass nil/empty to clear.
    func updateEntryNote(
        entryId: UUID,
        note: String?
    ) async throws -> LedgerEntry

    /// Money 2.0 Phase 4.4 (mig 20260526040000): batch-issue pool
    /// charges (cuotas / poker buy-ins / aportaciones esperadas) to N
    /// debtors with one flat amount. Inserts one `obligations` row per
    /// debtor with `kind='pool_charge'`, `owed_to_member_id=NULL`,
    /// `status='open'`. Idempotent via `clientId` — same client_id
    /// returns the full original batch instead of duplicating.
    /// Returns the inserted obligations.
    func issuePoolCharges(
        groupId: UUID,
        debtorMemberIds: [UUID],
        amountCents: Int64,
        currency: String,
        reason: String?,
        dueAt: Date?,
        sourceResourceId: UUID?,
        clientId: UUID
    ) async throws -> [Obligation]

    /// Money 2.0 Phase 4.4 (mig 20260526040000): closes a single pool
    /// charge. Emits a `contribution` ledger entry (cash inflow to the
    /// pool) AND marks the obligation `settled` atomically. Supports
    /// tri-role payer — `paidByMemberId` defaults to the debtor but a
    /// third party can cover the cuota. Idempotent via `clientId`.
    func payPoolCharge(
        obligationId: UUID,
        paidByMemberId: UUID?,
        note: String?,
        clientId: UUID
    ) async throws -> LedgerEntry

    /// Money 2.0 Phase 4.4 (mig 20260526040000): void an unpaid pool
    /// charge. Auth gated to group admins or the original issuer (the
    /// member who called `issuePoolCharges`). Idempotent on already-
    /// voided rows. Cannot void `settled` obligations.
    func voidPoolCharge(
        obligationId: UUID,
        reason: String?
    ) async throws -> Obligation
}

// MARK: - Mock

public actor MockLedgerRepository: LedgerRepository {
    private var entries: [LedgerEntry]
    /// Money 2.0 Phase 4.4: in-memory pool charges (cuotas) so previews
    /// + tests can exercise the issue/pay/void flow without a Postgres
    /// backend. Mirrors the `obligations` rows we'd see in production.
    private var poolCharges: [Obligation] = []

    public init(seed: [LedgerEntry] = [], poolCharges: [Obligation] = []) {
        self.entries = seed
        self.poolCharges = poolCharges
    }

    public func list(groupId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        entries.filter { $0.groupId == groupId }.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }

    public func listForResource(_ resourceId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        entries.filter { $0.resourceId == resourceId }.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        entries.filter { $0.fromMemberId == memberId || $0.toMemberId == memberId }
            .sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }

    public func record(_ entry: LedgerEntry) async throws -> LedgerEntry {
        entries.append(entry)
        return entry
    }

    public func recordEntry(
        groupId: UUID,
        resourceId: UUID?,
        type: String,
        amountCents: Int64,
        fromMemberId: UUID?,
        toMemberId: UUID?,
        currency: String = "MXN",
        metadata: JSONConfig = .object([:])
    ) async throws -> LedgerEntry {
        let entry = LedgerEntry(
            groupId: groupId,
            resourceId: resourceId,
            type: type,
            amountCents: amountCents,
            currency: currency,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            metadata: metadata
        )
        entries.append(entry)
        return entry
    }

    public func recordSettlement(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String = "MXN",
        resourceId: UUID? = nil,
        note: String? = nil
    ) async throws -> LedgerEntry {
        var metadata: JSONConfig = .object([:])
        if let note, !note.isEmpty {
            metadata = .object(["note": .string(note)])
        }
        let entry = LedgerEntry(
            groupId: groupId,
            resourceId: resourceId,
            type: "settlement",
            amountCents: amountCents,
            currency: currency,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            metadata: metadata
        )
        entries.append(entry)
        return entry
    }

    public func recordSettlementV2(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        clientId: UUID,
        sourceResourceId: UUID?
    ) async throws -> Settlement {
        let resolvedCurrency = currency ?? "MXN"
        // Append the audit ledger row so balance projections stay
        // consistent in previews. Mock skips the obligation status
        // bookkeeping — that's only meaningful against the live backend.
        let entry = LedgerEntry(
            groupId: groupId,
            resourceId: nil,
            type: LedgerEntry.Kind.settlement,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            metadata: .object([
                "client_id": .string(clientId.uuidString.lowercased())
            ])
        )
        entries.append(entry)
        let now = Date()
        return Settlement(
            id: UUID(),
            groupId: groupId,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            amountCents: amountCents,
            currency: resolvedCurrency,
            status: .confirmed,
            ledgerEntryId: entry.id,
            sourceResourceId: sourceResourceId,
            note: note,
            clientId: clientId,
            recordedBy: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    public func myBalancesAcrossGroups(
        userId: UUID,
        groupIds: [UUID]
    ) async throws -> [MemberGroupBalance] {
        // Mock doesn't model user→member membership, so the in-memory
        // implementation can't filter to "the viewer's row". Returns
        // empty — previews + tests just hide the card. The Live path
        // does the real two-query walk.
        []
    }

    public func updateEntryNote(
        entryId: UUID,
        note: String?
    ) async throws -> LedgerEntry {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else {
            throw LedgerError.rpcFailed("entry not found")
        }
        var meta: [String: JSONConfig] = {
            if case .object(let dict) = entries[idx].metadata { return dict }
            return [:]
        }()
        let trimmed = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            meta.removeValue(forKey: "note")
        } else {
            meta["note"] = .string(trimmed)
        }
        let original = entries[idx]
        let updated = LedgerEntry(
            id: original.id,
            groupId: original.groupId,
            resourceId: original.resourceId,
            type: original.type,
            amountCents: original.amountCents,
            currency: original.currency,
            fromMemberId: original.fromMemberId,
            toMemberId: original.toMemberId,
            metadata: .object(meta),
            occurredAt: original.occurredAt,
            recordedAt: original.recordedAt,
            recordedBy: original.recordedBy
        )
        entries[idx] = updated
        return updated
    }

    public func reverseEntry(
        entryId: UUID,
        reason: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        // Mock: append a settlement-shaped entry with the same
        // metadata convention so the in-memory store reflects the
        // reversal. The math holds because MockLedgerRepository's
        // `balancesForGroup` sums by from/to across all types — the
        // flipped from/to cancels the original.
        guard let original = entries.first(where: { $0.id == entryId }) else {
            throw LedgerError.rpcFailed("entry not found")
        }
        var meta: [String: JSONConfig] = [
            "reversed_ledger_entry_id": .string(entryId.uuidString.lowercased()),
            "reversed_original_type": .string(original.type),
            "client_id": .string(clientId.uuidString.lowercased())
        ]
        if let reason, !reason.isEmpty {
            meta["reason"] = .string(reason)
        }
        let reverse = LedgerEntry(
            groupId: original.groupId,
            resourceId: original.resourceId,
            type: "settlement",
            amountCents: original.amountCents,
            currency: original.currency,
            fromMemberId: original.toMemberId,
            toMemberId: original.fromMemberId,
            metadata: .object(meta)
        )
        entries.append(reverse)
        return reverse
    }

    public func balancesForGroup(_ groupId: UUID) async throws -> [MemberGroupBalance] {
        // Mock aggregates from in-memory entries by (member_id,
        // currency). Mirrors the server view's math: sent = sum where
        // member is `from_member_id`, received = sum where member is
        // `to_member_id`, net = received - sent.
        var sent: [String: Int64] = [:]
        var received: [String: Int64] = [:]
        for e in entries where e.groupId == groupId {
            if let m = e.fromMemberId {
                sent["\(m.uuidString)|\(e.currency)", default: 0] += e.amountCents
            }
            if let m = e.toMemberId {
                received["\(m.uuidString)|\(e.currency)", default: 0] += e.amountCents
            }
        }
        let keys = Set(sent.keys).union(received.keys)
        return keys.compactMap { key -> MemberGroupBalance? in
            let parts = key.split(separator: "|")
            guard parts.count == 2,
                  let memberId = UUID(uuidString: String(parts[0])) else { return nil }
            let currency = String(parts[1])
            let s = sent[key] ?? 0
            let r = received[key] ?? 0
            return MemberGroupBalance(
                groupId: groupId,
                memberId: memberId,
                currency: currency,
                sentCents: s,
                receivedCents: r,
                netCents: r - s
            )
        }
    }

    public func recordPayout(
        groupId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String,
        note: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        var meta: [String: JSONConfig] = [
            "client_id": .string(clientId.uuidString)
        ]
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            meta["note"] = .string(n)
        }
        let entry = LedgerEntry(
            groupId: groupId,
            resourceId: nil,
            type: LedgerEntry.Kind.payout,
            amountCents: amountCents,
            currency: currency,
            fromMemberId: nil,
            toMemberId: toMemberId,
            metadata: .object(meta)
        )
        entries.append(entry)
        return entry
    }

    public func obligationsTable(_ groupId: UUID) async throws -> [Obligation] {
        // Mock mirrors backend triggers + RPCs:
        //   1. Peer obligations: for each `expense` entry with
        //      `split_breakdown`, materialize one obligation per
        //      non-fronter participant.
        //   2. Pool charges (Phase 4.4): straight from in-memory
        //      `poolCharges` storage seeded by `issuePoolCharges`.
        // Status defaults to .open; settlement linkage isn't modeled in
        // the in-memory store (that's a backend concern via bridge).
        var out: [Obligation] = []
        for e in entries where e.groupId == groupId
            && e.type == LedgerEntry.Kind.expense
            && !e.splitBreakdown.isEmpty
            && e.toMemberId != nil {
            let fronter = e.toMemberId!
            for share in e.splitBreakdown where share.memberId != fronter && share.shareCents > 0 {
                out.append(Obligation(
                    id: UUID(),
                    groupId: groupId,
                    sourceMovementId: e.id,
                    owedByMemberId: share.memberId,
                    owedToMemberId: fronter,
                    amountCents: share.shareCents,
                    currency: e.currency,
                    status: .open,
                    sourceResourceId: e.sourceResourceId,
                    kind: .peer,
                    createdAt: e.recordedAt,
                    updatedAt: e.recordedAt
                ))
            }
        }
        out.append(contentsOf: poolCharges.filter { $0.groupId == groupId })
        return out
    }

    public func issuePoolCharges(
        groupId: UUID,
        debtorMemberIds: [UUID],
        amountCents: Int64,
        currency: String,
        reason: String?,
        dueAt: Date?,
        sourceResourceId: UUID?,
        clientId: UUID
    ) async throws -> [Obligation] {
        // Idempotency: matching client_id returns the original batch.
        let existing = poolCharges.filter {
            $0.groupId == groupId && $0.clientId == clientId
        }
        if !existing.isEmpty {
            return existing.sorted { $0.createdAt < $1.createdAt }
        }
        let now = Date()
        var batchMeta: [String: JSONConfig] = ["kind": .string("pool_charge")]
        if let reason, !reason.isEmpty {
            batchMeta["reason"] = .string(reason)
        }
        let inserted = debtorMemberIds.map { debtor in
            Obligation(
                id: UUID(),
                groupId: groupId,
                sourceMovementId: nil,
                owedByMemberId: debtor,
                owedToMemberId: nil,
                amountCents: amountCents,
                currency: currency,
                status: .open,
                sourceResourceId: sourceResourceId,
                kind: .poolCharge,
                clientId: clientId,
                dueAt: dueAt,
                metadata: .object(batchMeta),
                createdAt: now,
                updatedAt: now
            )
        }
        poolCharges.append(contentsOf: inserted)
        return inserted
    }

    public func payPoolCharge(
        obligationId: UUID,
        paidByMemberId: UUID?,
        note: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        guard let idx = poolCharges.firstIndex(where: { $0.id == obligationId }) else {
            throw LedgerError.rpcFailed("obligation not found")
        }
        let charge = poolCharges[idx]
        guard charge.kind == .poolCharge else {
            throw LedgerError.rpcFailed("obligation is not a pool charge")
        }
        guard charge.isActive else {
            throw LedgerError.rpcFailed("obligation is not payable")
        }
        let payer = paidByMemberId ?? charge.owedByMemberId
        var meta: [String: JSONConfig] = [
            "source_obligation_id": .string(obligationId.uuidString.lowercased()),
            "owed_by_member_id": .string(charge.owedByMemberId.uuidString.lowercased()),
            "client_id": .string(clientId.uuidString.lowercased())
        ]
        if let reason = charge.reason {
            meta["pool_charge_reason"] = .string(reason)
        }
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            meta["note"] = .string(n)
        }
        if let paidByMemberId, paidByMemberId != charge.owedByMemberId {
            meta["paid_by_member_id"] = .string(payer.uuidString.lowercased())
        }
        let entry = LedgerEntry(
            groupId: charge.groupId,
            resourceId: nil,
            type: LedgerEntry.Kind.contribution,
            amountCents: charge.amountCents,
            currency: charge.currency,
            fromMemberId: payer,
            toMemberId: nil,
            metadata: .object(meta)
        )
        entries.append(entry)
        // Close the obligation.
        poolCharges[idx] = Obligation(
            id: charge.id,
            groupId: charge.groupId,
            sourceMovementId: charge.sourceMovementId,
            owedByMemberId: charge.owedByMemberId,
            owedToMemberId: charge.owedToMemberId,
            amountCents: charge.amountCents,
            currency: charge.currency,
            status: .settled,
            sourceResourceId: charge.sourceResourceId,
            kind: charge.kind,
            clientId: charge.clientId,
            dueAt: charge.dueAt,
            metadata: charge.metadata,
            createdAt: charge.createdAt,
            updatedAt: Date()
        )
        return entry
    }

    public func voidPoolCharge(
        obligationId: UUID,
        reason: String?
    ) async throws -> Obligation {
        guard let idx = poolCharges.firstIndex(where: { $0.id == obligationId }) else {
            throw LedgerError.rpcFailed("obligation not found")
        }
        let charge = poolCharges[idx]
        if charge.status == .voided { return charge }
        guard charge.kind == .poolCharge else {
            throw LedgerError.rpcFailed("obligation is not a pool charge")
        }
        guard charge.status != .settled else {
            throw LedgerError.rpcFailed("cannot void a settled obligation")
        }
        var meta: [String: JSONConfig] = {
            if case .object(let dict) = charge.metadata { return dict }
            return [:]
        }()
        if let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            meta["voided_reason"] = .string(r)
        }
        let updated = Obligation(
            id: charge.id,
            groupId: charge.groupId,
            sourceMovementId: charge.sourceMovementId,
            owedByMemberId: charge.owedByMemberId,
            owedToMemberId: charge.owedToMemberId,
            amountCents: charge.amountCents,
            currency: charge.currency,
            status: .voided,
            sourceResourceId: charge.sourceResourceId,
            kind: charge.kind,
            clientId: charge.clientId,
            dueAt: charge.dueAt,
            metadata: .object(meta),
            createdAt: charge.createdAt,
            updatedAt: Date()
        )
        poolCharges[idx] = updated
        return updated
    }

    public func obligationsForGroup(_ groupId: UUID) async throws -> [MemberObligationSummary] {
        // Mock mirrors `member_obligations_view`: per (member, currency)
        // breakdown of stake / receivable / obligation / settlement.
        // Phase 4.4: `obligation_cents` includes both fines outstanding
        // AND active pool charges (cuotas).
        struct Key: Hashable { let memberId: UUID; let currency: String }
        var stake: [Key: Int64] = [:]
        var stakeInKind: [Key: Int64] = [:]
        var expenseOwed: [Key: Int64] = [:]
        var reimbursed: [Key: Int64] = [:]
        var finesIssued: [Key: Int64] = [:]
        var finesPaid: [Key: Int64] = [:]
        var finesVoided: [Key: Int64] = [:]
        var settleRecv: [Key: Int64] = [:]
        var settleSent: [Key: Int64] = [:]
        var poolChargeOblig: [Key: Int64] = [:]
        for charge in poolCharges where charge.groupId == groupId && charge.isActive {
            let k = Key(memberId: charge.owedByMemberId, currency: charge.currency)
            poolChargeOblig[k, default: 0] += charge.amountCents
        }
        for e in entries where e.groupId == groupId {
            switch e.type {
            case LedgerEntry.Kind.contribution:
                if let m = e.fromMemberId {
                    let k = Key(memberId: m, currency: e.currency)
                    if e.isInKind {
                        stakeInKind[k, default: 0] += e.amountCents
                    } else {
                        stake[k, default: 0] += e.amountCents
                    }
                }
            case LedgerEntry.Kind.expense:
                if let m = e.toMemberId {
                    expenseOwed[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            case LedgerEntry.Kind.reimbursement:
                if let m = e.fromMemberId ?? e.toMemberId {
                    reimbursed[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            case LedgerEntry.Kind.payout:
                if let m = e.toMemberId {
                    reimbursed[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            case LedgerEntry.Kind.fineIssued:
                if let m = e.fromMemberId {
                    finesIssued[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            case LedgerEntry.Kind.finePaid:
                if let m = e.fromMemberId {
                    finesPaid[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            case "fine_voided":
                if let m = e.fromMemberId {
                    finesVoided[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            case LedgerEntry.Kind.settlement:
                if let m = e.toMemberId {
                    settleRecv[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
                if let m = e.fromMemberId {
                    settleSent[Key(memberId: m, currency: e.currency), default: 0] += e.amountCents
                }
            default:
                break
            }
        }
        let allKeys = Set<Key>()
            .union(stake.keys)
            .union(stakeInKind.keys)
            .union(expenseOwed.keys)
            .union(reimbursed.keys)
            .union(finesIssued.keys)
            .union(finesPaid.keys)
            .union(finesVoided.keys)
            .union(settleRecv.keys)
            .union(settleSent.keys)
            .union(poolChargeOblig.keys)
        return allKeys.map { k in
            let receivable = max(0, (expenseOwed[k] ?? 0) - (reimbursed[k] ?? 0))
            let fineOblig = max(0,
                (finesIssued[k] ?? 0) - (finesPaid[k] ?? 0) - (finesVoided[k] ?? 0)
            )
            let obligation = fineOblig + (poolChargeOblig[k] ?? 0)
            let netPeer = receivable + (settleRecv[k] ?? 0) - obligation - (settleSent[k] ?? 0)
            return MemberObligationSummary(
                groupId: groupId,
                memberId: k.memberId,
                currency: k.currency,
                stakeCents: stake[k] ?? 0,
                stakeInKindCents: stakeInKind[k] ?? 0,
                receivableCents: receivable,
                obligationCents: obligation,
                settlementReceivedCents: settleRecv[k] ?? 0,
                settlementSentCents: settleSent[k] ?? 0,
                netPeerPositionCents: netPeer
            )
        }
    }
}

// MARK: - Live

public actor LiveLedgerRepository: LedgerRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func list(groupId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        do {
            return try await client
                .from("ledger_entries")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForResource(_ resourceId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        do {
            return try await client
                .from("ledger_entries")
                .select("*")
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        do {
            // Two queries (from + to) merged client-side. Postgrest doesn't
            // support OR across columns natively without rpc.
            async let fromTask: [LedgerEntry] = client
                .from("ledger_entries")
                .select("*")
                .eq("from_member_id", value: memberId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            async let toTask: [LedgerEntry] = client
                .from("ledger_entries")
                .select("*")
                .eq("to_member_id", value: memberId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            let (fromEntries, toEntries) = try await (fromTask, toTask)
            let combined = (fromEntries + toEntries)
            // De-dup + re-sort by occurredAt desc.
            var seen: Set<UUID> = []
            return combined.filter { entry in
                if seen.contains(entry.id) { return false }
                seen.insert(entry.id)
                return true
            }.sorted { $0.occurredAt > $1.occurredAt }
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func record(_ entry: LedgerEntry) async throws -> LedgerEntry {
        do {
            return try await client
                .from("ledger_entries")
                .insert(entry)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordEntry(
        groupId: UUID,
        resourceId: UUID?,
        type: String,
        amountCents: Int64,
        fromMemberId: UUID?,
        toMemberId: UUID?,
        currency: String = "MXN",
        metadata: JSONConfig = .object([:])
    ) async throws -> LedgerEntry {
        // Mig 00360 (2026-05-21) changed `record_ledger_entry` to take
        // 9 args (added `p_source_resource_id`) and DROPPED the legacy
        // 8-arg overload. iOS must send ALL 9 keys — and crucially, nil
        // values must serialize as JSON `null`, not be OMITTED. Swift's
        // default Encodable for Optional<String> OMITS nil keys (uses
        // `encodeIfPresent`), which makes PostgREST look for a 6-arg
        // overload that doesn't exist. The custom `encode(to:)` below
        // forces explicit nulls via `encodeNil(forKey:)`.
        struct Params: Encodable {
            let p_group_id: String
            let p_resource_id: String?
            let p_type: String
            let p_amount_cents: Int64
            let p_from_member_id: String?
            let p_to_member_id: String?
            let p_currency: String
            let p_metadata: JSONConfig
            let p_source_resource_id: String?

            enum CodingKeys: String, CodingKey {
                case p_group_id, p_resource_id, p_type, p_amount_cents
                case p_from_member_id, p_to_member_id
                case p_currency, p_metadata, p_source_resource_id
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_group_id, forKey: .p_group_id)
                try c.encode(p_type, forKey: .p_type)
                try c.encode(p_amount_cents, forKey: .p_amount_cents)
                try c.encode(p_currency, forKey: .p_currency)
                try c.encode(p_metadata, forKey: .p_metadata)
                // Force JSON `null` for the optional UUID keys so the
                // function-name resolution sees all 9 keys.
                if let v = p_resource_id {
                    try c.encode(v, forKey: .p_resource_id)
                } else {
                    try c.encodeNil(forKey: .p_resource_id)
                }
                if let v = p_from_member_id {
                    try c.encode(v, forKey: .p_from_member_id)
                } else {
                    try c.encodeNil(forKey: .p_from_member_id)
                }
                if let v = p_to_member_id {
                    try c.encode(v, forKey: .p_to_member_id)
                } else {
                    try c.encodeNil(forKey: .p_to_member_id)
                }
                if let v = p_source_resource_id {
                    try c.encode(v, forKey: .p_source_resource_id)
                } else {
                    try c.encodeNil(forKey: .p_source_resource_id)
                }
            }
        }
        do {
            return try await client
                .rpc("record_ledger_entry", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_resource_id: resourceId?.uuidString.lowercased(),
                    p_type: type,
                    p_amount_cents: amountCents,
                    p_from_member_id: fromMemberId?.uuidString.lowercased(),
                    p_to_member_id: toMemberId?.uuidString.lowercased(),
                    p_currency: currency,
                    p_metadata: metadata,
                    p_source_resource_id: nil
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordSettlement(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String = "MXN",
        resourceId: UUID? = nil,
        note: String? = nil
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_group_id: String
            let p_from_member_id: String
            let p_to_member_id: String
            let p_amount_cents: Int64
            let p_currency: String
            let p_resource_id: String?
            let p_note: String?
        }
        do {
            return try await client
                .rpc("record_settlement", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_from_member_id: fromMemberId.uuidString.lowercased(),
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_resource_id: resourceId?.uuidString.lowercased(),
                    p_note: note?.isEmpty == true ? nil : note
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordSettlementV2(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        clientId: UUID,
        sourceResourceId: UUID?
    ) async throws -> Settlement {
        // Mig 20260526010500: 8-arg RPC. Same explicit-null pattern as
        // `record_payout` — Swift's default encoder OMITS nil keys, so
        // we force null via a custom `encode(to:)`.
        struct Params: Encodable {
            let p_group_id: String
            let p_from_member_id: String
            let p_to_member_id: String
            let p_amount_cents: Int64
            let p_currency: String?
            let p_note: String?
            let p_client_id: String
            let p_source_resource_id: String?

            enum CodingKeys: String, CodingKey {
                case p_group_id, p_from_member_id, p_to_member_id, p_amount_cents
                case p_currency, p_note, p_client_id, p_source_resource_id
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_group_id, forKey: .p_group_id)
                try c.encode(p_from_member_id, forKey: .p_from_member_id)
                try c.encode(p_to_member_id, forKey: .p_to_member_id)
                try c.encode(p_amount_cents, forKey: .p_amount_cents)
                try c.encode(p_client_id, forKey: .p_client_id)
                if let v = p_currency { try c.encode(v, forKey: .p_currency) }
                else { try c.encodeNil(forKey: .p_currency) }
                if let v = p_note { try c.encode(v, forKey: .p_note) }
                else { try c.encodeNil(forKey: .p_note) }
                if let v = p_source_resource_id { try c.encode(v, forKey: .p_source_resource_id) }
                else { try c.encodeNil(forKey: .p_source_resource_id) }
            }
        }
        do {
            let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await client
                .rpc("record_settlement_v2", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_from_member_id: fromMemberId.uuidString.lowercased(),
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote,
                    p_client_id: clientId.uuidString.lowercased(),
                    p_source_resource_id: sourceResourceId?.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func balancesForGroup(_ groupId: UUID) async throws -> [MemberGroupBalance] {
        do {
            return try await client
                .from("member_balances_per_group")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func obligationsForGroup(_ groupId: UUID) async throws -> [MemberObligationSummary] {
        do {
            return try await client
                .from("member_obligations_view")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func obligationsTable(_ groupId: UUID) async throws -> [Obligation] {
        do {
            return try await client
                .from("obligations")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordPayout(
        groupId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String,
        note: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        // Mig 20260525233000: 7-arg RPC with explicit nulls. Same
        // pattern as `record_ledger_entry` — Swift's default encoder
        // OMITS nil keys, so we force null via a custom `encode(to:)`.
        struct Params: Encodable {
            let p_group_id: String
            let p_to_member_id: String
            let p_amount_cents: Int64
            let p_currency: String?
            let p_note: String?
            let p_client_id: String
            let p_source_resource_id: String?

            enum CodingKeys: String, CodingKey {
                case p_group_id, p_to_member_id, p_amount_cents
                case p_currency, p_note, p_client_id, p_source_resource_id
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_group_id, forKey: .p_group_id)
                try c.encode(p_to_member_id, forKey: .p_to_member_id)
                try c.encode(p_amount_cents, forKey: .p_amount_cents)
                try c.encode(p_client_id, forKey: .p_client_id)
                if let v = p_currency { try c.encode(v, forKey: .p_currency) }
                else { try c.encodeNil(forKey: .p_currency) }
                if let v = p_note { try c.encode(v, forKey: .p_note) }
                else { try c.encodeNil(forKey: .p_note) }
                if let v = p_source_resource_id { try c.encode(v, forKey: .p_source_resource_id) }
                else { try c.encodeNil(forKey: .p_source_resource_id) }
            }
        }
        do {
            return try await client
                .rpc("record_payout", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_note: (note?.isEmpty == false) ? note : nil,
                    p_client_id: clientId.uuidString.lowercased(),
                    p_source_resource_id: nil
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func reverseEntry(
        entryId: UUID,
        reason: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_entry_id: String
            let p_reason: String?
            let p_client_id: String
        }
        do {
            return try await client
                .rpc("reverse_ledger_entry", params: Params(
                    p_entry_id: entryId.uuidString.lowercased(),
                    p_reason: (reason?.isEmpty == false) ? reason : nil,
                    p_client_id: clientId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateEntryNote(
        entryId: UUID,
        note: String?
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_entry_id: String
            let p_note: String?
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            return try await client
                .rpc("update_ledger_entry_note", params: Params(
                    p_entry_id: entryId.uuidString.lowercased(),
                    p_note: cleaned
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func myBalancesAcrossGroups(
        userId: UUID,
        groupIds: [UUID]
    ) async throws -> [MemberGroupBalance] {
        guard !groupIds.isEmpty else { return [] }
        do {
            // Step 1: resolve the viewer's `group_members.id` per group.
            // RLS allows reading own membership rows.
            struct MembershipRow: Decodable {
                let id: UUID
            }
            let groupIdStrings = groupIds.map { $0.uuidString.lowercased() }
            let memberships: [MembershipRow] = try await client
                .from("group_members")
                .select("id")
                .eq("user_id", value: userId.uuidString.lowercased())
                .in("group_id", values: groupIdStrings)
                .execute()
                .value
            let memberIds = memberships.map { $0.id.uuidString.lowercased() }
            guard !memberIds.isEmpty else { return [] }

            // Step 2: read balance rows for those member ids. The view's
            // composite key already includes group_id so no extra
            // disambiguation is needed.
            return try await client
                .from("member_balances_per_group")
                .select()
                .in("member_id", values: memberIds)
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    // MARK: - Pool charges (Phase 4.4, mig 20260526040000)

    public func issuePoolCharges(
        groupId: UUID,
        debtorMemberIds: [UUID],
        amountCents: Int64,
        currency: String,
        reason: String?,
        dueAt: Date?,
        sourceResourceId: UUID?,
        clientId: UUID
    ) async throws -> [Obligation] {
        // PostgREST resolves overloads by parameter names — every key
        // must be present in the JSON, even if nil. Custom encoder
        // forces explicit `encodeNil` for the optional ones.
        struct Params: Encodable {
            let p_group_id: String
            let p_debtor_member_ids: [String]
            let p_amount_cents: Int64
            let p_currency: String?
            let p_reason: String?
            let p_due_at: String?
            let p_source_resource_id: String?
            let p_client_id: String

            enum CodingKeys: String, CodingKey {
                case p_group_id, p_debtor_member_ids, p_amount_cents
                case p_currency, p_reason, p_due_at, p_source_resource_id, p_client_id
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_group_id, forKey: .p_group_id)
                try c.encode(p_debtor_member_ids, forKey: .p_debtor_member_ids)
                try c.encode(p_amount_cents, forKey: .p_amount_cents)
                try c.encode(p_client_id, forKey: .p_client_id)
                if let v = p_currency { try c.encode(v, forKey: .p_currency) }
                else { try c.encodeNil(forKey: .p_currency) }
                if let v = p_reason { try c.encode(v, forKey: .p_reason) }
                else { try c.encodeNil(forKey: .p_reason) }
                if let v = p_due_at { try c.encode(v, forKey: .p_due_at) }
                else { try c.encodeNil(forKey: .p_due_at) }
                if let v = p_source_resource_id { try c.encode(v, forKey: .p_source_resource_id) }
                else { try c.encodeNil(forKey: .p_source_resource_id) }
            }
        }
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        // ISO 8601 with fractional seconds matches Postgres timestamptz
        // parsing and round-trips cleanly through PostgREST.
        let dueAtString: String? = dueAt.map { ISO8601DateFormatter().string(from: $0) }
        do {
            return try await client
                .rpc("issue_pool_charges", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_debtor_member_ids: debtorMemberIds.map { $0.uuidString.lowercased() },
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_reason: (trimmedReason?.isEmpty ?? true) ? nil : trimmedReason,
                    p_due_at: dueAtString,
                    p_source_resource_id: sourceResourceId?.uuidString.lowercased(),
                    p_client_id: clientId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func payPoolCharge(
        obligationId: UUID,
        paidByMemberId: UUID?,
        note: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_obligation_id: String
            let p_paid_by_member_id: String?
            let p_note: String?
            let p_client_id: String

            enum CodingKeys: String, CodingKey {
                case p_obligation_id, p_paid_by_member_id, p_note, p_client_id
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_obligation_id, forKey: .p_obligation_id)
                try c.encode(p_client_id, forKey: .p_client_id)
                if let v = p_paid_by_member_id { try c.encode(v, forKey: .p_paid_by_member_id) }
                else { try c.encodeNil(forKey: .p_paid_by_member_id) }
                if let v = p_note { try c.encode(v, forKey: .p_note) }
                else { try c.encodeNil(forKey: .p_note) }
            }
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await client
                .rpc("pay_pool_charge", params: Params(
                    p_obligation_id: obligationId.uuidString.lowercased(),
                    p_paid_by_member_id: paidByMemberId?.uuidString.lowercased(),
                    p_note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                    p_client_id: clientId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func voidPoolCharge(
        obligationId: UUID,
        reason: String?
    ) async throws -> Obligation {
        struct Params: Encodable {
            let p_obligation_id: String
            let p_reason: String?

            enum CodingKeys: String, CodingKey {
                case p_obligation_id, p_reason
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_obligation_id, forKey: .p_obligation_id)
                if let v = p_reason { try c.encode(v, forKey: .p_reason) }
                else { try c.encodeNil(forKey: .p_reason) }
            }
        }
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await client
                .rpc("void_pool_charge", params: Params(
                    p_obligation_id: obligationId.uuidString.lowercased(),
                    p_reason: (trimmed?.isEmpty ?? true) ? nil : trimmed
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }
}
