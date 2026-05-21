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
    /// Sum of all `contribution`-typed ledger entries against the
    /// shared pool in this currency.
    public let inCents: Int64
    /// Sum of all `expense`-typed ledger entries.
    public let outCents: Int64
    /// `inCents - outCents`. Can go negative when expenses exceed
    /// contributions — that's a valid IOU state for the group.
    public let balanceCents: Int64
    /// Total count of ledger entries feeding this row.
    public let entryCount: Int64
    /// Most-recent `occurred_at` across the feeding entries. Nil when
    /// the pool has zero activity yet.
    public let lastActivityAt: Date?

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
    }

    public init(
        groupId: UUID,
        currency: String,
        sharedPoolId: UUID,
        inCents: Int64,
        outCents: Int64,
        balanceCents: Int64,
        entryCount: Int64,
        lastActivityAt: Date?
    ) {
        self.groupId = groupId
        self.currency = currency
        self.sharedPoolId = sharedPoolId
        self.inCents = inCents
        self.outCents = outCents
        self.balanceCents = balanceCents
        self.entryCount = entryCount
        self.lastActivityAt = lastActivityAt
    }
}
