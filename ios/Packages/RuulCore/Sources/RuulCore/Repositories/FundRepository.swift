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

    /// SharedMoney Phase 3 brick 1 (mig 00361): the canonical shared
    /// pool's projection for a group. Returns nil ONLY in the defensive
    /// case where the invariant "every active group has one shared
    /// pool" has been violated (migs 00357 + 00359 normally prevent
    /// this). V1 callers select the row matching `groups.currency`;
    /// multi-currency UI (V1.5+) may take all rows by reading the view
    /// directly.
    ///
    /// `preferredCurrency`: when supplied, picks the row matching that
    /// currency. When nil, returns the first row (deterministic order
    /// in single-currency V1).
    func summaryForGroup(
        _ groupId: UUID,
        preferredCurrency: String?
    ) async throws -> SharedPoolSummary?

    /// SharedMoney Phase 4 (mig 00362): per-resource money projection.
    /// Aggregates ledger entries tagged with `source_resource_id`
    /// matching `resourceId`. Used by the resource detail Money Block
    /// (events first, then assets/spaces) to render "Gastos de este
    /// evento" without ever creating a per-event fund.
    ///
    /// Returns nil when the resource has zero attributed activity —
    /// the view only emits rows for resources with at least one
    /// expense/contribution. UI handles the empty state with a calm
    /// "Aún no hay movimientos asociados a este {evento|recurso}"
    /// prompt + the "Registrar gasto" CTA.
    ///
    /// `preferredCurrency` mirrors `summaryForGroup` semantics: V1
    /// passes the group currency; multi-currency UI (V1.5+) may read
    /// the view directly for all rows.
    func summaryForResource(
        _ resourceId: UUID,
        preferredCurrency: String?
    ) async throws -> ResourceMoneySummary?

    /// SharedMoney Phase 4.5: per-member contribution breakdown for a
    /// source resource. Returns one row per `from_member_id` who has
    /// contributed via entries tagged with `source_resource_id`. Sums
    /// `amount_cents` over `type='contribution'` only (reimbursements
    /// are pool→member outflows, not capital injection — see the
    /// in-kind doctrine). Used to render "Tú $X (40%) · Socio $Y (60%)"
    /// inside the Resource Money Block; the percentage is derived
    /// client-side from the row totals.
    ///
    /// `preferredCurrency` filters to a single currency for V1 single-
    /// currency groups. Pass `nil` to get all currencies (V1.5+).
    ///
    /// Returns an empty array when the resource has zero contribution
    /// activity. Order is undefined — UI sorts by amount descending.
    func breakdownForResource(
        _ resourceId: UUID,
        preferredCurrency: String?
    ) async throws -> [ResourceMemberContribution]

    /// Records a contribution from the caller (member) to the fund.
    /// `currency` falls through to fund metadata then to MXN if nil.
    /// `note` lands in the ledger entry's metadata jsonb. `sourceEventId`
    /// (mig 00344) attributes the entry to a specific event so the
    /// event's money tab can render event-scoped balances without
    /// duplicating the fund per event. `clientId` (mig 00351) is an
    /// idempotency key — sheets hold a stable UUID in `@State` so a
    /// re-tap after a network error reuses the same key and the backend
    /// returns the existing row instead of inserting a duplicate.
    func contribute(
        fundId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        sourceEventId: UUID?,
        clientId: UUID?
    ) async throws -> LedgerEntry

    /// Records an expense FROM the fund TO a recipient member. Vendor
    /// expenses without a recipient are out of scope (the projection
    /// uses direction-based balance math). `sourceEventId` (mig 00344)
    /// attributes the entry to a specific event. `clientId` (mig 00351)
    /// is an idempotency key — same semantics as `contribute`.
    /// `paidByMemberId` (mig 00355) is the "en nombre de" annotation:
    /// who actually fronted the cash, distinct from `toMemberId` (who
    /// receives the reimbursement) and `recorded_by` (auth.uid(),
    /// stamped server-side). Lands in `metadata.paid_by_member_id`.
    /// Nil = registrar is implicitly the payer (legacy behavior).
    func recordExpense(
        fundId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?,
        sourceEventId: UUID?,
        clientId: UUID?,
        paidByMemberId: UUID?
    ) async throws -> LedgerEntry

    /// SharedMoney Phase 2 (mig 00363): group-scoped expense entry point.
    /// Caller supplies `groupId` only — the wrapper resolves the canonical
    /// shared pool internally and delegates to `fund_record_expense`. iOS
    /// no longer needs to know the shared pool's `fundId` for the default
    /// "money lives in the group" flow. Protected funds (Phase 6) continue
    /// using `recordExpense(fundId:…)` directly.
    ///
    /// `sourceResourceId` (mig 00356/00360) attributes the entry to a
    /// specific event/asset/space/etc. — the generic context pointer that
    /// supersedes the legacy `sourceEventId`. Other params mirror
    /// `recordExpense`.
    ///
    /// `participants` (mig 00367, P4): when non-empty, stamps
    /// `metadata.participants` so UI surfaces can compute per-share =
    /// amount/N. V1 doesn't auto-generate per-participant IOUs; users
    /// settle manually via the existing settle-up flow.
    func recordSharedExpense(
        groupId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?,
        sourceResourceId: UUID?,
        clientId: UUID?,
        paidByMemberId: UUID?,
        participants: [UUID],
        splitMode: SplitMode?,
        splitBreakdown: [SplitBreakdown]?
    ) async throws -> LedgerEntry

    /// SharedMoney Phase 2 (mig 00363): group-scoped contribution entry
    /// point. Symmetric counterpart of `recordSharedExpense` — resolves
    /// the shared pool internally and delegates to `fund_contribute`.
    /// `inKind` (mig 00364, Phase 4.5) stamps `metadata.in_kind=true`
    /// when set — distinguishes capital-in-kind aportes (terreno,
    /// equipo) from cash. Passive annotation today; future surfaces
    /// can break the breakdown down by kind.
    func contributeToSharedMoney(
        groupId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        sourceResourceId: UUID?,
        clientId: UUID?,
        inKind: Bool
    ) async throws -> LedgerEntry

    /// Admin-only soft lock. Emits `fundLocked`. Does NOT block writers
    /// — lock-aware behavior is delegated to rules.
    func lock(fundId: UUID, reason: String?) async throws

    /// Admin-only lock release. Emits `fundUnlocked`.
    func unlock(fundId: UUID) async throws

    /// SharedMoney Phase 6 (mig 00365): admin-only, idempotent.
    /// Promotes a fund to "protected" status by stamping
    /// `metadata.is_protected_fund=true`. Raises on the shared pool
    /// (XOR with is_shared_pool, mig 00358 CHECK). Used by the
    /// "Marcar como fondo separado" action on a fund's detail page
    /// when the user wants this fund out of the canonical surface.
    func markProtected(fundId: UUID) async throws
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

    public func summaryForGroup(
        _ groupId: UUID,
        preferredCurrency: String? = nil
    ) async throws -> SharedPoolSummary? {
        // Mock derives the summary from the seeded Fund snapshot for
        // the group. Test fixtures should seed exactly one fund per
        // group (the implicit shared pool) for deterministic behavior
        // — server-side resolution is authoritative.
        let candidates = funds.values.flatMap { $0 }
            .filter { $0.groupId == groupId }
        guard !candidates.isEmpty else { return nil }
        let pick: Fund
        if let preferredCurrency,
           let matching = candidates.first(where: { $0.currency == preferredCurrency }) {
            pick = matching
        } else {
            pick = candidates[0]
        }
        return SharedPoolSummary(
            groupId: groupId,
            currency: pick.currency,
            sharedPoolId: pick.fundId,
            inCents: pick.inCents,
            outCents: pick.outCents,
            balanceCents: pick.balanceCents,
            entryCount: pick.contributionCount + pick.expenseCount,
            lastActivityAt: pick.lastActivityAt
        )
    }

    public func summaryForResource(
        _ resourceId: UUID,
        preferredCurrency: String? = nil
    ) async throws -> ResourceMoneySummary? {
        // Mock derives the per-resource summary by scanning the Mock's
        // in-memory `entries` for matches on metadata.source_resource_id.
        // The Mock writes that key in `recordSharedExpense` /
        // `contributeToSharedMoney` (Phase 2). Mirrors the server-side
        // `resource_money_view` math (mig 00362): expense + contribution
        // types only; other types excluded.
        let matches = entries.filter { entry in
            guard entry.type == LedgerEntry.Kind.expense
                  || entry.type == LedgerEntry.Kind.contribution else { return false }
            return entry.metadata["source_resource_id"]?.stringValue
                == resourceId.uuidString.lowercased()
        }
        guard !matches.isEmpty else { return nil }
        // Currency pick: prefer requested, else fall back to the most
        // common currency in the matches (deterministic for V1 single
        // currency — every match has the same).
        let currency = preferredCurrency
            ?? matches.first?.currency
            ?? "MXN"
        let scoped = matches.filter { $0.currency == currency }
        guard !scoped.isEmpty else { return nil }

        let spent = scoped
            .filter { $0.type == LedgerEntry.Kind.expense }
            .map(\.amountCents).reduce(0, +)
        let contributed = scoped
            .filter { $0.type == LedgerEntry.Kind.contribution }
            .map(\.amountCents).reduce(0, +)
        let payers = Set(scoped.compactMap {
            $0.metadata["paid_by_member_id"]?.stringValue
        })
        let lastActivity = scoped.map(\.occurredAt).max()
        // Latest recorded_by — most-recent entry's recorder.
        let latestRecorder = scoped
            .sorted { $0.occurredAt > $1.occurredAt }
            .first?.recordedBy

        // groupId of the first match — all matches share the same group
        // since RPC validates source_resource_id is in the fund's group.
        let groupId = scoped[0].groupId

        return ResourceMoneySummary(
            groupId: groupId,
            sourceResourceId: resourceId,
            currency: currency,
            spentCents: spent,
            contributedCents: contributed,
            entryCount: Int64(scoped.count),
            lastActivityAt: lastActivity,
            payerCount: Int64(payers.count),
            latestRecordedBy: latestRecorder
        )
    }

    public func breakdownForResource(
        _ resourceId: UUID,
        preferredCurrency: String? = nil
    ) async throws -> [ResourceMemberContribution] {
        // Mock aggregates from in-memory entries matching
        // `(source_resource_id, type='contribution')` grouped by
        // from_member_id. Mirrors the Live impl's policy: only
        // contribution-typed entries with a non-null from_member_id
        // count toward member capital.
        let matches = entries.filter { entry in
            guard entry.type == LedgerEntry.Kind.contribution else { return false }
            guard entry.fromMemberId != nil else { return false }
            return entry.metadata["source_resource_id"]?.stringValue
                == resourceId.uuidString.lowercased()
        }
        guard !matches.isEmpty else { return [] }
        let currency = preferredCurrency
            ?? matches.first?.currency
            ?? "MXN"
        let scoped = matches.filter { $0.currency == currency }
        guard !scoped.isEmpty else { return [] }

        var totals: [UUID: (Int64, Int)] = [:]
        for entry in scoped {
            guard let m = entry.fromMemberId else { continue }
            let cur = totals[m] ?? (0, 0)
            totals[m] = (cur.0 + entry.amountCents, cur.1 + 1)
        }
        return totals.map { (m, agg) in
            ResourceMemberContribution(
                memberId: m,
                contributedCents: agg.0,
                entryCount: agg.1
            )
        }
    }

    public func contribute(
        fundId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        sourceEventId: UUID? = nil,
        clientId: UUID? = nil
    ) async throws -> LedgerEntry {
        guard let snapshot = funds[fundId]?.first else { throw FundError.notFound }
        // Mirror the server-side V1-01 dedup: if clientId already exists
        // among recorded entries, return the prior row. Lets feature
        // tests verify retry-idempotency without a live backend.
        if let clientId,
           let existing = entries.first(where: {
               $0.metadata["client_id"]?.stringValue == clientId.uuidString.lowercased()
           }) {
            return existing
        }
        let resolvedCurrency = currency ?? snapshot.currency
        var meta: [String: JSONConfig] = [:]
        if let note, !note.isEmpty { meta["note"] = .string(note) }
        if let sourceEventId { meta["source_event_id"] = .string(sourceEventId.uuidString.lowercased()) }
        if let clientId { meta["client_id"] = .string(clientId.uuidString.lowercased()) }
        let entry = LedgerEntry(
            groupId: snapshot.groupId,
            resourceId: fundId,
            type: LedgerEntry.Kind.contribution,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: UUID(),
            toMemberId: nil,
            metadata: .object(meta)
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
        note: String?,
        sourceEventId: UUID? = nil,
        clientId: UUID? = nil,
        paidByMemberId: UUID? = nil
    ) async throws -> LedgerEntry {
        guard let snapshot = funds[fundId]?.first else { throw FundError.notFound }
        if let clientId,
           let existing = entries.first(where: {
               $0.metadata["client_id"]?.stringValue == clientId.uuidString.lowercased()
           }) {
            return existing
        }
        let resolvedCurrency = currency ?? snapshot.currency
        var meta: [String: JSONConfig] = [:]
        if let note, !note.isEmpty { meta["note"] = .string(note) }
        if let sourceEventId { meta["source_event_id"] = .string(sourceEventId.uuidString.lowercased()) }
        if let clientId { meta["client_id"] = .string(clientId.uuidString.lowercased()) }
        if let paidByMemberId { meta["paid_by_member_id"] = .string(paidByMemberId.uuidString.lowercased()) }
        let entry = LedgerEntry(
            groupId: snapshot.groupId,
            resourceId: fundId,
            type: LedgerEntry.Kind.expense,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: nil,
            toMemberId: toMemberId,
            metadata: .object(meta)
        )
        entries.append(entry)
        rebuildSnapshot(for: fundId)
        return entry
    }

    public func recordSharedExpense(
        groupId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?,
        sourceResourceId: UUID? = nil,
        clientId: UUID? = nil,
        paidByMemberId: UUID? = nil,
        participants: [UUID] = [],
        splitMode: SplitMode? = nil,
        splitBreakdown: [SplitBreakdown]? = nil
    ) async throws -> LedgerEntry {
        // Mock shared-pool resolution: pick any fund for the group. The
        // is_shared_pool flag lives in resources.metadata server-side and
        // isn't surfaced by fund_balance_view, so test fixtures should
        // seed exactly one fund per group for deterministic behavior.
        guard let snapshot = funds.values.flatMap({ $0 })
            .first(where: { $0.groupId == groupId }) else {
            throw FundError.notFound
        }
        if let clientId,
           let existing = entries.first(where: {
               $0.metadata["client_id"]?.stringValue == clientId.uuidString.lowercased()
           }) {
            return existing
        }
        let resolvedCurrency = currency ?? snapshot.currency
        var meta: [String: JSONConfig] = [:]
        if let note, !note.isEmpty { meta["note"] = .string(note) }
        if let sourceResourceId { meta["source_resource_id"] = .string(sourceResourceId.uuidString.lowercased()) }
        if let clientId { meta["client_id"] = .string(clientId.uuidString.lowercased()) }
        if let paidByMemberId { meta["paid_by_member_id"] = .string(paidByMemberId.uuidString.lowercased()) }
        if !participants.isEmpty {
            meta["participants"] = .array(participants.map { .string($0.uuidString.lowercased()) })
        }
        if let splitMode {
            meta["split_mode"] = .string(splitMode.rawValue)
        }
        if let splitBreakdown, !splitBreakdown.isEmpty {
            meta["split_breakdown"] = .array(splitBreakdown.map { row in
                .object([
                    "member_id":   .string(row.memberId.uuidString.lowercased()),
                    "share_cents": .int(Int(row.shareCents))
                ])
            })
        }
        let entry = LedgerEntry(
            groupId: snapshot.groupId,
            resourceId: snapshot.fundId,
            type: LedgerEntry.Kind.expense,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: nil,
            toMemberId: toMemberId,
            metadata: .object(meta)
        )
        entries.append(entry)
        rebuildSnapshot(for: snapshot.fundId)
        return entry
    }

    public func contributeToSharedMoney(
        groupId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        sourceResourceId: UUID? = nil,
        clientId: UUID? = nil,
        inKind: Bool = false
    ) async throws -> LedgerEntry {
        // Mock shared-pool resolution: pick any fund for the group. The
        // is_shared_pool flag lives in resources.metadata server-side and
        // isn't surfaced by fund_balance_view, so test fixtures should
        // seed exactly one fund per group for deterministic behavior.
        guard let snapshot = funds.values.flatMap({ $0 })
            .first(where: { $0.groupId == groupId }) else {
            throw FundError.notFound
        }
        if let clientId,
           let existing = entries.first(where: {
               $0.metadata["client_id"]?.stringValue == clientId.uuidString.lowercased()
           }) {
            return existing
        }
        let resolvedCurrency = currency ?? snapshot.currency
        var meta: [String: JSONConfig] = [:]
        if let note, !note.isEmpty { meta["note"] = .string(note) }
        if let sourceResourceId { meta["source_resource_id"] = .string(sourceResourceId.uuidString.lowercased()) }
        if let clientId { meta["client_id"] = .string(clientId.uuidString.lowercased()) }
        if inKind { meta["in_kind"] = .bool(true) }
        let entry = LedgerEntry(
            groupId: snapshot.groupId,
            resourceId: snapshot.fundId,
            type: LedgerEntry.Kind.contribution,
            amountCents: amountCents,
            currency: resolvedCurrency,
            fromMemberId: UUID(),
            toMemberId: nil,
            metadata: .object(meta)
        )
        entries.append(entry)
        rebuildSnapshot(for: snapshot.fundId)
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

    public func markProtected(fundId: UUID) async throws {
        // Mock no-op: the Fund projection doesn't carry the
        // is_protected_fund flag client-side (it lives in
        // resources.metadata server-side). Real implementations call
        // the RPC; the Mock just verifies the fund exists so callers
        // can rely on `notFound` semantics in tests.
        guard funds[fundId]?.first != nil else { throw FundError.notFound }
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

    public func summaryForGroup(
        _ groupId: UUID,
        preferredCurrency: String? = nil
    ) async throws -> SharedPoolSummary? {
        // Read all currency rows; V1 picks the one matching the
        // group's currency, multi-currency V1.5+ may surface all.
        do {
            let rows: [SharedPoolSummary] = try await client
                .from("group_money_summary_view")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .execute()
                .value
            if let preferredCurrency,
               let matching = rows.first(where: { $0.currency == preferredCurrency }) {
                return matching
            }
            return rows.first
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func summaryForResource(
        _ resourceId: UUID,
        preferredCurrency: String? = nil
    ) async throws -> ResourceMoneySummary? {
        // Read all currency rows for this source_resource_id; V1 picks
        // the one matching the group's currency. The view (mig 00362)
        // only emits rows for resources with at least one attributed
        // entry, so a missing result == "no movements yet" — caller
        // renders the empty-state copy.
        do {
            let rows: [ResourceMoneySummary] = try await client
                .from("resource_money_view")
                .select()
                .eq("source_resource_id", value: resourceId.uuidString.lowercased())
                .execute()
                .value
            if let preferredCurrency,
               let matching = rows.first(where: { $0.currency == preferredCurrency }) {
                return matching
            }
            return rows.first
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func breakdownForResource(
        _ resourceId: UUID,
        preferredCurrency: String? = nil
    ) async throws -> [ResourceMemberContribution] {
        // Phase 4.5 brick A: client-side aggregation from raw
        // ledger_entries. No backend view needed — query the rows
        // filtered to (source_resource_id, type='contribution'),
        // optionally currency, then group by from_member_id in Swift.
        // Scale: a project resource (warehouse, viaje) accumulates
        // tens of entries, not thousands, so 500 is a generous cap.
        struct RawEntry: Decodable {
            let from_member_id: UUID?
            let amount_cents: Int64
            let currency: String
        }
        do {
            var query = client
                .from("ledger_entries")
                .select("from_member_id,amount_cents,currency")
                .eq("source_resource_id", value: resourceId.uuidString.lowercased())
                .eq("type", value: LedgerEntry.Kind.contribution)
                .not("from_member_id", operator: .is, value: "null")
            if let preferredCurrency {
                query = query.eq("currency", value: preferredCurrency)
            }
            let rows: [RawEntry] = try await query
                .limit(500)
                .execute()
                .value

            var totals: [UUID: (Int64, Int)] = [:]
            for r in rows {
                guard let m = r.from_member_id else { continue }
                let cur = totals[m] ?? (0, 0)
                totals[m] = (cur.0 + r.amount_cents, cur.1 + 1)
            }
            return totals.map { (m, agg) in
                ResourceMemberContribution(
                    memberId: m,
                    contributedCents: agg.0,
                    entryCount: agg.1
                )
            }
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func contribute(
        fundId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        sourceEventId: UUID? = nil,
        clientId: UUID? = nil
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_fund_id: String
            let p_amount_cents: Int64
            let p_currency: String?
            let p_note: String?
            let p_source_event_id: String?
            let p_client_id: String?
        }
        do {
            return try await client
                .rpc("fund_contribute", params: Params(
                    p_fund_id: fundId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_note: (note?.isEmpty ?? true) ? nil : note,
                    p_source_event_id: sourceEventId?.uuidString.lowercased(),
                    p_client_id: clientId?.uuidString.lowercased()
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
        note: String?,
        sourceEventId: UUID? = nil,
        clientId: UUID? = nil,
        paidByMemberId: UUID? = nil
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_fund_id: String
            let p_amount_cents: Int64
            let p_to_member_id: String
            let p_currency: String?
            let p_note: String?
            let p_source_event_id: String?
            let p_client_id: String?
            let p_paid_by_member_id: String?
        }
        do {
            return try await client
                .rpc("fund_record_expense", params: Params(
                    p_fund_id: fundId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_currency: currency,
                    p_note: (note?.isEmpty ?? true) ? nil : note,
                    p_source_event_id: sourceEventId?.uuidString.lowercased(),
                    p_client_id: clientId?.uuidString.lowercased(),
                    p_paid_by_member_id: paidByMemberId?.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordSharedExpense(
        groupId: UUID,
        amountCents: Int64,
        toMemberId: UUID,
        currency: String?,
        note: String?,
        sourceResourceId: UUID? = nil,
        clientId: UUID? = nil,
        paidByMemberId: UUID? = nil,
        participants: [UUID] = [],
        splitMode: SplitMode? = nil,
        splitBreakdown: [SplitBreakdown]? = nil
    ) async throws -> LedgerEntry {
        struct BreakdownRow: Encodable {
            let member_id: String
            let share_cents: Int64
        }
        struct Params: Encodable {
            let p_group_id: String
            let p_amount_cents: Int64
            let p_to_member_id: String
            let p_currency: String?
            let p_note: String?
            let p_source_resource_id: String?
            let p_client_id: String?
            let p_paid_by_member_id: String?
            let p_participants: [String]?
            let p_split_mode: String?
            let p_split_breakdown: [BreakdownRow]?
        }
        do {
            return try await client
                .rpc("record_shared_expense", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_currency: currency,
                    p_note: (note?.isEmpty ?? true) ? nil : note,
                    p_source_resource_id: sourceResourceId?.uuidString.lowercased(),
                    p_client_id: clientId?.uuidString.lowercased(),
                    p_paid_by_member_id: paidByMemberId?.uuidString.lowercased(),
                    p_participants: participants.isEmpty
                        ? nil
                        : participants.map { $0.uuidString.lowercased() },
                    p_split_mode: splitMode?.rawValue,
                    p_split_breakdown: splitBreakdown.flatMap { rows in
                        rows.isEmpty ? nil : rows.map {
                            BreakdownRow(
                                member_id: $0.memberId.uuidString.lowercased(),
                                share_cents: $0.shareCents
                            )
                        }
                    }
                ))
                .execute()
                .value
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }

    public func contributeToSharedMoney(
        groupId: UUID,
        amountCents: Int64,
        currency: String?,
        note: String?,
        sourceResourceId: UUID? = nil,
        clientId: UUID? = nil,
        inKind: Bool = false
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_group_id: String
            let p_amount_cents: Int64
            let p_currency: String?
            let p_note: String?
            let p_source_resource_id: String?
            let p_client_id: String?
            let p_in_kind: Bool
        }
        do {
            return try await client
                .rpc("contribute_to_shared_money", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_note: (note?.isEmpty ?? true) ? nil : note,
                    p_source_resource_id: sourceResourceId?.uuidString.lowercased(),
                    p_client_id: clientId?.uuidString.lowercased(),
                    p_in_kind: inKind
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

    public func markProtected(fundId: UUID) async throws {
        struct Params: Encodable { let p_fund_id: String }
        do {
            try await client
                .rpc("mark_fund_protected", params: Params(
                    p_fund_id: fundId.uuidString.lowercased()
                ))
                .execute()
        } catch {
            throw FundError.rpcFailed(error.localizedDescription)
        }
    }
}
