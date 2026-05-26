import Foundation

/// Projection: one row of `public.group_money_summary_view` (mig 00361).
///
/// Per the SharedMoney doctrine (founder 2026-05-21), every active
/// group has exactly one canonical shared pool — a fund row stamped
/// `metadata.is_shared_pool=true` (seeded by mig 00357 on create,
/// backfilled to legacy groups by mig 00359). This projection answers
/// "how much money is in that pool, and when was the last movement?"
/// in a single read.
///
/// Scope: this view is INTENTIONALLY scoped to the shared pool only.
/// Protected funds (Phase 6) and legacy fund rows surface via
/// `fund_balance_view` instead — they are not aggregated here.
///
/// Math: derived from `ledger_entries` filtered to entries whose
/// `resource_id` matches the group's shared pool fund. Only
/// contribution + expense types feed the totals. Settlement, payout,
/// and fine_* types are excluded — they have their own surfaces
/// (member_balances_per_*) and Phase 5 obligations will fold them in.
///
/// Empty-state: a fresh group with no ledger activity surfaces with
/// `balanceCents = 0, entryCount = 0, lastActivityAt = nil` and the
/// currency from `resources.metadata.currency` (typically the group's
/// declared currency at create time).
///
/// V1 single-currency: callers read the single row matching
/// `groups.currency`. The view returns one row per (group, currency)
/// so multi-currency activity (V1.5+) produces multiple rows.
public struct SharedPoolSummary: Projection, Identifiable, Hashable {
    public static var projectionViewName: String { "group_money_summary_view" }

    public let groupId: UUID
    public let currency: String
    /// The canonical shared pool's `resources.id`. Useful as a write
    /// target for any flow that still needs the fund id (e.g.,
    /// `fund_lock`/`unlock`, or future migrations).
    public let sharedPoolId: UUID
    /// Sum of CASH `contribution`-typed ledger entries against the
    /// shared pool in this currency. FASE 4 Wave 4 (mig 20260525221500):
    /// narrows from "all contributions" to "cash contributions only" —
    /// in-kind contributions surface separately via `inKindCents`.
    public let inCents: Int64
    /// Sum of all `expense`-typed ledger entries.
    public let outCents: Int64
    /// `inCents - outCents` (cash flow only). Excludes in-kind
    /// contributions per FASE 4 Wave 4 (mig 20260525221500). Use
    /// `totalValueCents` for the gross value that includes assets.
    public let balanceCents: Int64
    /// Total count of ledger entries feeding this row.
    public let entryCount: Int64
    /// Most-recent `occurred_at` across the feeding entries. Nil when
    /// the pool has zero activity yet.
    public let lastActivityAt: Date?
    /// FASE 4 Wave 4 (mig 20260525221500): sum of in-kind `contribution`
    /// entries (metadata.in_kind = true) — assets aportados en especie
    /// (terrenos, equipo, etc). Surfaced apart from `inCents` so the
    /// pool number reflects cash flow, not gross asset value.
    public let inKindCents: Int64
    /// FASE 4 Wave 4: gross pool value = cash balance + in-kind. Useful
    /// for surfaces that want the "total worth of the pool including
    /// assets", e.g. capital reports.
    public let totalValueCents: Int64

    /// Composite id for SwiftUI ForEach. Group + currency is the
    /// natural key (one row per currency in the projection).
    public var id: String { "\(groupId.uuidString)|\(currency)" }

    /// True when the pool has had any ledger activity. UI uses this
    /// to switch between "Aún sin movimientos" and a populated state.
    public var hasActivity: Bool { entryCount > 0 }

    /// True when the pool's balance is negative. UI flips money tone
    /// to `.warning` when this is true.
    public var isOverSpent: Bool { balanceCents < 0 }

    public enum CodingKeys: String, CodingKey {
        case groupId          = "group_id"
        case currency
        case sharedPoolId     = "shared_pool_id"
        case inCents          = "shared_pool_in_cents"
        case outCents         = "shared_pool_out_cents"
        case balanceCents     = "shared_pool_balance_cents"
        case entryCount       = "entry_count"
        case lastActivityAt   = "last_activity_at"
        case inKindCents      = "shared_pool_in_kind_cents"
        case totalValueCents  = "shared_pool_total_value_cents"
    }

    public init(
        groupId: UUID,
        currency: String,
        sharedPoolId: UUID,
        inCents: Int64,
        outCents: Int64,
        balanceCents: Int64,
        entryCount: Int64,
        lastActivityAt: Date?,
        inKindCents: Int64 = 0,
        totalValueCents: Int64? = nil
    ) {
        self.groupId = groupId
        self.currency = currency
        self.sharedPoolId = sharedPoolId
        self.inCents = inCents
        self.outCents = outCents
        self.balanceCents = balanceCents
        self.entryCount = entryCount
        self.lastActivityAt = lastActivityAt
        self.inKindCents = inKindCents
        // Default: cash balance + in-kind. Allows older callers /
        // mock fixtures to skip the param without changing values.
        self.totalValueCents = totalValueCents ?? (balanceCents + inKindCents)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.currency = try c.decode(String.self, forKey: .currency)
        self.sharedPoolId = try c.decode(UUID.self, forKey: .sharedPoolId)
        self.inCents = try Self.decodeCents(c, .inCents)
        self.outCents = try Self.decodeCents(c, .outCents)
        self.balanceCents = try Self.decodeCents(c, .balanceCents)
        self.entryCount = try Self.decodeCents(c, .entryCount)
        self.lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        // Backward compat: tolerate missing keys for callers reading
        // legacy fixtures or pre-mig-20260525221500 snapshots.
        self.inKindCents = (try? Self.decodeCents(c, .inKindCents)) ?? 0
        self.totalValueCents = (try? Self.decodeCents(c, .totalValueCents))
            ?? (self.balanceCents + self.inKindCents)
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
