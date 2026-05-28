import Foundation

/// V2-G2 sub-slice 6 — kinds the inline pool_charge handler in
/// `finalize_vote` accepts. Mirrors the backend CHECK
/// (`record_pool_charge` validates the same three values).
public enum PoolChargeKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case quota
    case buyIn = "buy_in"
    case fee

    public var id: String { rawValue }

    public static let displayOrder: [PoolChargeKind] = [.quota, .buyIn, .fee]

    public var label: LocalizedStringResource {
        switch self {
        case .quota: return L10n.Decisions.poolChargeKindQuota
        case .buyIn: return L10n.Decisions.poolChargeKindBuyIn
        case .fee:   return L10n.Decisions.poolChargeKindFee
        }
    }

    public var systemImageName: String {
        switch self {
        case .quota: return "calendar.badge.clock"
        case .buyIn: return "ticket"
        case .fee:   return "creditcard"
        }
    }
}
