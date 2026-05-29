import Foundation

/// One row of the Splitwise-style "Settle up" plan from the caller's
/// perspective. `netAmount > 0` ⇒ the caller owes that net amount to
/// the counterparty; `netAmount < 0` ⇒ the counterparty owes the
/// caller. Pool obligations (multas, buy-ins) are excluded by doctrine
/// from this plan — they live in their own surface.
///
/// Returned by `group_settlement_plan_for_member(group, member)` and
/// ordered by `|netAmount| DESC` so the UI shows the biggest knots
/// first.
public struct SettlementPlanItem: Sendable, Hashable, Identifiable {
    public var id: UUID { counterpartyMembershipId }
    public let counterpartyMembershipId: UUID
    public let counterpartyDisplayName: String
    public let netAmount: Decimal
    public let unit: String

    public init(
        counterpartyMembershipId: UUID,
        counterpartyDisplayName: String,
        netAmount: Decimal,
        unit: String
    ) {
        self.counterpartyMembershipId = counterpartyMembershipId
        self.counterpartyDisplayName = counterpartyDisplayName
        self.netAmount = netAmount
        self.unit = unit
    }

    /// Sign-aware direction of the suggestion.
    public enum Direction: Sendable, Equatable {
        /// Caller should pay this amount to the counterparty.
        case youOwe
        /// Counterparty should pay this amount to the caller.
        case theyOwe
    }

    public var direction: Direction {
        netAmount > 0 ? .youOwe : .theyOwe
    }

    /// Always positive — the magnitude of the net obligation in the
    /// item's currency unit. Use this for display.
    public var absoluteAmount: Decimal {
        netAmount < 0 ? -netAmount : netAmount
    }
}
