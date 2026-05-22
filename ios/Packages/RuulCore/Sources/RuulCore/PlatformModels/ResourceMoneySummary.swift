import Foundation

/// Projection: one row of `public.resource_money_view` (mig 00362).
///
/// Per the SharedMoney doctrine (founder 2026-05-21), a *source resource*
/// — an event, asset, space, or any other context — does NOT own its
/// own money. It provides *attribution*: ledger entries record where
/// they relate via `source_resource_id`. This projection answers "for
/// this resource, how much was spent / contributed / by whom?" in a
/// single read.
///
/// Scope: aggregates ledger_entries where `source_resource_id IS NOT
/// NULL` and `type IN ('expense', 'contribution')`. Other types
/// (settlement, payout, fine_*) are silently excluded — they have
/// their own surfaces and Phase 5 obligations will fold them in.
///
/// Independence from the fund: rows here are attribution-keyed, not
/// fund-keyed. A contribution to the shared pool tagged
/// `source_resource_id=<event>` AND an expense from a protected fund
/// tagged with the same source both surface here. From the resource's
/// perspective, "money I'm responsible for" doesn't care which
/// compartment it came from.
///
/// Empty state: rows ONLY appear when at least one ledger entry exists
/// with the matching `source_resource_id`. A resource with zero
/// attributed movements has no row — UI must handle the "no movements
/// yet" copy. Intentional: a view over LEFT-joined resources would
/// explode in size (every resource × every group, mostly zeros).
public struct ResourceMoneySummary: Projection, Identifiable, Hashable {
    public static var projectionViewName: String { "resource_money_view" }

    public let groupId: UUID
    /// The event / asset / space / right / etc. this row aggregates.
    public let sourceResourceId: UUID
    public let currency: String
    /// Sum of `expense`-typed ledger entries.
    public let spentCents: Int64
    /// Sum of `contribution`-typed ledger entries.
    public let contributedCents: Int64
    public let entryCount: Int64
    public let lastActivityAt: Date?
    /// Distinct `metadata.paid_by_member_id` count when present. Zero
    /// when no entry carries the paid-by annotation. Useful for "X
    /// personas pagaron" surfaces.
    public let payerCount: Int64
    /// `recorded_by` of the most-recent feeding entry. UI uses for
    /// "última actividad por X" hints in the block footer.
    public let latestRecordedBy: UUID?

    /// Composite id for SwiftUI ForEach. Source + currency is the
    /// natural key (one row per currency per source).
    public var id: String { "\(sourceResourceId.uuidString)|\(currency)" }

    /// Net cents = contributed - spent. Negative when expenses exceed
    /// contributions (typical for "people paid for this event from
    /// their pocket and the group owes them").
    public var netCents: Int64 { contributedCents - spentCents }

    /// True when the resource has had any attributed activity.
    public var hasActivity: Bool { entryCount > 0 }

    public enum CodingKeys: String, CodingKey {
        case groupId            = "group_id"
        case sourceResourceId   = "source_resource_id"
        case currency
        case spentCents         = "spent_cents"
        case contributedCents   = "contributed_cents"
        case entryCount         = "entry_count"
        case lastActivityAt     = "last_activity_at"
        case payerCount         = "payer_count"
        case latestRecordedBy   = "latest_recorded_by"
    }

    public init(
        groupId: UUID,
        sourceResourceId: UUID,
        currency: String,
        spentCents: Int64,
        contributedCents: Int64,
        entryCount: Int64,
        lastActivityAt: Date?,
        payerCount: Int64,
        latestRecordedBy: UUID?
    ) {
        self.groupId = groupId
        self.sourceResourceId = sourceResourceId
        self.currency = currency
        self.spentCents = spentCents
        self.contributedCents = contributedCents
        self.entryCount = entryCount
        self.lastActivityAt = lastActivityAt
        self.payerCount = payerCount
        self.latestRecordedBy = latestRecordedBy
    }
}
