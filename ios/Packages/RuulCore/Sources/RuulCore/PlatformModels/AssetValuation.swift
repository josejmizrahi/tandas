import Foundation

/// Projection: one row of `public.asset_valuation_view`. An append-only
/// log of valuation atoms emitted by `record_valuation` —
/// the projection just surfaces them in chronological order.
///
/// SharedMoney Phase 4.5+ (P1 link): the `ContributeToSharedMoneySheet`
/// reads the LATEST row to pre-fill the amount when a user contributes
/// an asset in-kind to a resource. Keeps valuation and contribution
/// in sync as a single source of truth without forcing the user to
/// re-enter the same number in two places.
///
/// Per `doctrine_in_kind_contributions.md` — the warehouse case where
/// "I aporté el terreno valorado en $X" should pull X from the asset's
/// recorded valuation rather than requiring manual re-entry.
public struct AssetValuation: Projection, Hashable, Sendable {
    public static var projectionViewName: String { "asset_valuation_view" }

    public let assetId: UUID
    public let groupId: UUID
    public let valueCents: Int64
    public let currency: String
    /// Free-text source: "appraisal", "market_lookup", "agreed_value", etc.
    /// Stamped by the caller of `record_valuation`. Nil when not provided.
    public let source: String?
    public let notes: String?
    /// Stored as text in the view (uuid serialized) — keep matching shape.
    public let recordedByUserId: String?
    public let recordedAt: Date

    public enum CodingKeys: String, CodingKey {
        case assetId            = "asset_id"
        case groupId            = "group_id"
        case valueCents         = "value_cents"
        case currency
        case source
        case notes
        case recordedByUserId   = "recorded_by_user_id"
        case recordedAt         = "recorded_at"
    }

    public init(
        assetId: UUID,
        groupId: UUID,
        valueCents: Int64,
        currency: String,
        source: String? = nil,
        notes: String? = nil,
        recordedByUserId: String? = nil,
        recordedAt: Date
    ) {
        self.assetId = assetId
        self.groupId = groupId
        self.valueCents = valueCents
        self.currency = currency
        self.source = source
        self.notes = notes
        self.recordedByUserId = recordedByUserId
        self.recordedAt = recordedAt
    }
}
