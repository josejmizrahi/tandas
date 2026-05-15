import Foundation

/// Projection: one row of `public.fund_balance_view` (mig 00198).
///
/// A fund is a resource (`resources WHERE resource_type='fund'`) whose
/// balance, contribution count, expense count and last-activity are
/// derived at read time from `public.ledger_entries`. The view returns
/// **one row per (fund, currency)**: a fund with no flows yet returns a
/// single row using the currency stored in metadata; a fund with
/// multi-currency activity returns one row per currency.
///
/// `Fund` is a `Projection` marker — never persisted independently.
/// Recovery path is rerunning the view against the ledger atoms; the
/// iOS app holds these snapshots only for rendering.
public struct Fund: Projection, Identifiable, Hashable {
    public static var projectionViewName: String { "fund_balance_view" }

    public let fundId: UUID
    public let groupId: UUID
    public let name: String
    public let targetAmountCents: Int64?
    public let currency: String
    public let inCents: Int64
    public let outCents: Int64
    public let balanceCents: Int64
    public let contributionCount: Int64
    public let expenseCount: Int64
    public let lastActivityAt: Date?
    public let lockedAt: Date?
    public let lockedReason: String?
    public let archivedAt: Date?
    public let createdAt: Date

    /// Composite id for SwiftUI ForEach. fundId+currency is the natural
    /// key (one row per currency in the projection).
    public var id: String { "\(fundId.uuidString)|\(currency)" }

    /// True when `archivedAt` is non-nil. The view leaves the row visible
    /// to the founder via the same RLS surface as `resources_select_archived_founder`
    /// (mig 00184), so callers must guard render paths explicitly.
    public var isArchived: Bool { archivedAt != nil }

    /// True when `lockedAt` is non-nil. Lock is an admin-stamped state
    /// on `resources.metadata`; writers do not enforce it (Constitution §9
    /// delegates lock-aware behavior to rules). UI may dim or annotate
    /// the fund based on this flag.
    public var isLocked: Bool { lockedAt != nil }

    /// Convenience: how close to the target. Returns nil if no target is
    /// set or balance is non-positive. Range [0, 1+].
    public var progressTowardsTarget: Double? {
        guard let target = targetAmountCents, target > 0, balanceCents >= 0 else { return nil }
        return Double(balanceCents) / Double(target)
    }

    public enum CodingKeys: String, CodingKey {
        case fundId             = "fund_id"
        case groupId            = "group_id"
        case name
        case targetAmountCents  = "target_amount_cents"
        case currency
        case inCents            = "in_cents"
        case outCents           = "out_cents"
        case balanceCents       = "balance_cents"
        case contributionCount  = "contribution_count"
        case expenseCount       = "expense_count"
        case lastActivityAt     = "last_activity_at"
        case lockedAt           = "locked_at"
        case lockedReason       = "locked_reason"
        case archivedAt         = "archived_at"
        case createdAt          = "created_at"
    }

    public init(
        fundId: UUID,
        groupId: UUID,
        name: String,
        targetAmountCents: Int64?,
        currency: String,
        inCents: Int64,
        outCents: Int64,
        balanceCents: Int64,
        contributionCount: Int64,
        expenseCount: Int64,
        lastActivityAt: Date?,
        lockedAt: Date?,
        lockedReason: String?,
        archivedAt: Date?,
        createdAt: Date
    ) {
        self.fundId = fundId
        self.groupId = groupId
        self.name = name
        self.targetAmountCents = targetAmountCents
        self.currency = currency
        self.inCents = inCents
        self.outCents = outCents
        self.balanceCents = balanceCents
        self.contributionCount = contributionCount
        self.expenseCount = expenseCount
        self.lastActivityAt = lastActivityAt
        self.lockedAt = lockedAt
        self.lockedReason = lockedReason
        self.archivedAt = archivedAt
        self.createdAt = createdAt
    }
}
