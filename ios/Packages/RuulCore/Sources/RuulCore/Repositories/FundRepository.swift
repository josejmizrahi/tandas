import Foundation
import Supabase

public enum FundError: Error, Equatable {
    case rpcFailed(String)
    case notFound
}

/// Read/write surface for `resource_type='fund'` resources.
///
/// Reads come from `public.fund_balance_view` (mig 00198) — a projection
/// over `public.ledger_entries`. Writes go through dedicated RPCs that
/// validate the fund-specific invariants before delegating to
/// `record_ledger_entry` / `archive_resource`.
public protocol FundRepository: Actor {
    /// All funds (active + archived if the caller is founder, per the
    /// `resources_select_archived_founder` RLS policy) for a group.
    /// Returns one row per (fund, currency).
    func listForGroup(_ groupId: UUID) async throws -> [Fund]

    /// Snapshot for a single fund. Returns the row(s) keyed by
    /// `(fund_id, currency)` — typically one for V1 single-currency
    /// groups, but multi-currency activity surfaces multiple rows.
    func get(_ fundId: UUID) async throws -> [Fund]

    /// Records a contribution from the caller (member) to the fund.
    /// `currency` falls through to fund metadata then to MXN if nil.
    /// `note` lands in the ledger entry's metadata jsonb.
    func contribute(
        fundId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?
    ) async throws -> LedgerEntry

    /// Records an expense FROM the fund TO a recipient member. Vendor
    /// expenses without a recipient are out of scope (the projection
    /// uses direction-based balance math).
    func recordExpense(
        fundId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?
    ) async throws -> LedgerEntry

    /// Admin-only soft lock. Emits `fundLocked`. Does NOT block writers
    /// — lock-aware behavior is delegated to rules.
    func lock(fundId: UUID, reason: String?) async throws

    /// Admin-only lock release. Emits `fundUnlocked`.
    func unlock(fundId: UUID) async throws
}

// MARK: - Mock

public actor MockFundRepository: FundRepository {
    private var funds: [UUID: [Fund]]
    private var entries: [LedgerEntry]

    public init(seed: [Fund] = [], entries: [LedgerEntry] = []) {
        var indexed: [UUID: [Fund]] = [:]
        for f in seed { indexed[f.fundId, default: []].append(f) }
        self.funds = indexed
        self.entries = entries
    }

    public func listForGroup(_ groupId: UUID) async throws -> [Fund] {
        funds.values.flatMap { $0 }.filter { $0.groupId == groupId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func get(_ fundId: UUID) async throws -> [Fund] {
        funds[fundId] ?? []
    }

    public func contribute(
        fundId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?
    ) async throws -> LedgerEntry {
        guard let snapshot = funds[fundId]?.first else { throw FundError.notFound }
        let resolvedCurrency = currency ?? snapshot.currency
        var metadata: JSONConfig = .object([:])
        if let note, !note.isEmpty { metadata = .object(["note": .string(note)]) }
        let entry = LedgerEntry(
            groupId: snapshot.groupId,
            resourceId: fundId,
            type: LedgerEntry.Kind.contribution,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: UUID(),
            toMemberId: nil,
            metadata: metadata
        )
        entries.append(entry)
        rebuildSnapshot(for: fundId)
        return entry
    }

    public func recordExpense(
        fundId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?
    ) async throws -> LedgerEntry {
        guard let snapshot = funds[fundId]?.first else { throw FundError.notFound }
        let resolvedCurrency = currency ?? snapshot.currency
        var metadata: JSONConfig = .object([:])
        if let note, !note.isEmpty { metadata = .object(["note": .string(note)]) }
        let entry = LedgerEntry(
            groupId: snapshot.groupId,
            resourceId: fundId,
            type: LedgerEntry.Kind.expense,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: nil,
            toMemberId: toMemberId,
            metadata: metadata
        )
        entries.append(entry)
        rebuildSnapshot(for: fundId)
        return entry
    }

    public func lock(fundId: UUID, reason: String?) async throws {
        guard let original = funds[fundId]?.first else { throw FundError.notFound }
        // Idempotent: if already locked, preserve original lockedAt +
        // lockedReason so re-calling doesn't emit a second fundLocked
        // atom (mirrors the `fund_lock` server RPC contract per mig 00198
        // + Plans/Active/CleanupAudit_2026-05-18/08_tests.md §9.4 doctrine
        // — Atoms append-only, lock idempotency).
        if original.isLocked { return }
        let stamped = Fund(
            fundId: original.fundId,
            groupId: original.groupId,
            name: original.name,
            targetAmountCents: original.targetAmountCents,
            currency: original.currency,
            inCents: original.inCents,
            outCents: original.outCents,
            balanceCents: original.balanceCents,
            contributionCount: original.contributionCount,
            expenseCount: original.expenseCount,
            lastActivityAt: original.lastActivityAt,
            lockedAt: .now,
            lockedReason: reason,
            archivedAt: original.archivedAt,
            createdAt: original.createdAt
        )
        funds[fundId] = [stamped]
    }

    public func unlock(fundId: UUID) async throws {
        guard let original = funds[fundId]?.first else { throw FundError.notFound }
        // Symmetric idempotency: if already unlocked, no atom to emit.
        if !original.isLocked { return }
        let cleared = Fund(
            fundId: original.fundId,
            groupId: original.groupId,
            name: original.name,
            targetAmountCents: original.targetAmountCents,
            currency: original.currency,
            inCents: original.inCents,
            outCents: original.outCents,
            balanceCents: original.balanceCents,
            contributionCount: original.contributionCount,
            expenseCount: original.expenseCount,
            lastActivityAt: original.lastActivityAt,
            lockedAt: nil,
            lockedReason: nil,
            archivedAt: original.archivedAt,
            createdAt: original.createdAt
        )
        funds[fundId] = [cleared]
    }

    /// Test helper: install a snapshot so view code can render without
    /// needing the real projection.
    public func stub(_ snapshot: Fund) {
        funds[snapshot.fundId, default: []].append(snapshot)
    }

    private func rebuildSnapshot(for fundId: UUID) {
        guard let existing = funds[fundId]?.first else { return }
        let fundEntries = entries.filter { $0.resourceId == fundId }
        let inCents = fundEntries
            .filter { $0.fromMemberId != nil && $0.toMemberId == nil }
            .map(\.amountCents).reduce(0, +)
        let outCents = fundEntries
            .filter { $0.fromMemberId == nil && $0.toMemberId != nil }
            .map(\.amountCents).reduce(0, +)
        let contributionCount = Int64(fundEntries.filter { $0.type == LedgerEntry.Kind.contribution }.count)
        let expenseCount = Int64(fundEntries.filter { $0.type == LedgerEntry.Kind.expense }.count)
        let lastActivityAt = fundEntries.map(\.occurredAt).max()
        let updated = Fund(
            fundId: existing.fundId,
            groupId: existing.groupId,
            name: existing.name,
            targetAmountCents: existing.targetAmountCents,
            currency: existing.currency,
            inCents: inCents,
            outCents: outCents,
            balanceCents: inCents - outCents,
            contributionCount: contributionCount,
            expenseCount: expenseCount,
            lastActivityAt: lastActivityAt,
            lockedAt: existing.lockedAt,
            lockedReason: existing.lockedReason,
            archivedAt: existing.archivedAt,
            createdAt: existing.createdAt
        )
        funds[fundId] = [updated]
    }
}

// MARK: - Live

public actor LiveFundRepository: FundRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func listForGroup(_ groupId: UUID) async throws -> [Fund] {
        do {
            return try await client
                .from("fund_balance_view")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func get(_ fundId: UUID) async throws -> [Fund] {
        do {
            return try await client
                .from("fund_balance_view")
                .select()
                .eq("fund_id", value: fundId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func contribute(
        fundId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_fund_id: String
            let p_amount_cents: Int64
            let p_currency: String?
            let p_note: String?
        }
        do {
            return try await client
                .rpc("fund_contribute", params: Params(
                    p_fund_id: fundId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_note: (note?.isEmpty ?? true) ? nil : note
                ))
                .execute()
                .value
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordExpense(
        fundId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_fund_id: String
            let p_amount_cents: Int64
            let p_to_member_id: String
            let p_currency: String?
            let p_note: String?
        }
        do {
            return try await client
                .rpc("fund_record_expense", params: Params(
                    p_fund_id: fundId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_currency: currency,
                    p_note: (note?.isEmpty ?? true) ? nil : note
                ))
                .execute()
                .value
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func lock(fundId: UUID, reason: String?) async throws {
        struct Params: Encodable {
            let p_fund_id: String
            let p_reason: String?
        }
        do {
            try await client
                .rpc("fund_lock", params: Params(
                    p_fund_id: fundId.uuidString.lowercased(),
                    p_reason: (reason?.isEmpty ?? true) ? nil : reason
                ))
                .execute()
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func unlock(fundId: UUID) async throws {
        struct Params: Encodable { let p_fund_id: String }
        do {
            try await client
                .rpc("fund_unlock", params: Params(
                    p_fund_id: fundId.uuidString.lowercased()
                ))
                .execute()
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }
}
