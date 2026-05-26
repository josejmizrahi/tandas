import Foundation

/// FASE 4 Wave 4 / Phase 5 foundation (mig 20260525230000): per
/// (group, member, currency) breakdown of money state — replaces the
/// naïve `MemberGroupBalance.netCents` for surfaces that need to
/// distinguish capital injection from debt.
///
/// Why
/// ===
/// `MemberGroupBalance.netCents = received − sent` lumps three very
/// different things into one cifra:
///   1. Stake (contributions the member made — capital, NOT debt)
///   2. Receivable (pool owes member for fronted expenses)
///   3. Obligation (member owes group via fines outstanding)
///
/// The greedy peer settlement plan reading `netCents` ends up
/// suggesting payments that COMPOUND the imbalance. iOS "Tu posición"
/// reading `netCents` shows misleading "Le debes" labels for
/// contributors.
///
/// This projection separates the three dimensions plus settlements,
/// and computes `netPeerPositionCents` = the actionable peer-relevant
/// balance (excludes stake). Greedy should use THIS number, not
/// `MemberGroupBalance.netCents`.
public struct MemberObligationSummary: Projection, Identifiable, Hashable {
    public static var projectionViewName: String { "member_obligations_view" }

    public let groupId: UUID
    public let memberId: UUID
    public let currency: String

    /// Sum of cash `contribution` entries from this member. The
    /// member's "capital injected" — NOT a debt.
    public let stakeCents: Int64
    /// Sum of in-kind contributions (metadata.in_kind = true) — assets
    /// like terrenos / equipo / vehículos this member contributed.
    public let stakeInKindCents: Int64
    /// Pool owes this member: SUM(expense.to=member) − SUM(payout /
    /// reimbursement involving member). Clamped >= 0 server-side.
    public let receivableCents: Int64
    /// Member owes group: fines_issued − fines_paid − fines_voided
    /// from this member. Clamped >= 0 server-side (paid > issued
    /// rounds to 0 instead of negative).
    public let obligationCents: Int64
    /// Incoming peer settlements (other members paid me).
    public let settlementReceivedCents: Int64
    /// Outgoing peer settlements (I paid other members).
    public let settlementSentCents: Int64
    /// The actionable peer-relevant balance:
    ///   receivable + settlement_received − obligation − settlement_sent
    /// Positive: peers/pool owe me. Negative: I owe peers/pool. Zero:
    /// settled. EXCLUDES stake (contributions) — that's separate.
    public let netPeerPositionCents: Int64

    public var id: String {
        "\(groupId.uuidString)|\(memberId.uuidString)|\(currency)"
    }

    public var stakeTotalCents: Int64 { stakeCents + stakeInKindCents }
    public var hasAnyPosition: Bool {
        stakeTotalCents > 0
            || receivableCents > 0
            || obligationCents > 0
            || settlementReceivedCents > 0
            || settlementSentCents > 0
    }

    public enum CodingKeys: String, CodingKey {
        case groupId  = "group_id"
        case memberId = "member_id"
        case currency
        case stakeCents               = "stake_cents"
        case stakeInKindCents         = "stake_in_kind_cents"
        case receivableCents          = "receivable_cents"
        case obligationCents          = "obligation_cents"
        case settlementReceivedCents  = "settlement_received_cents"
        case settlementSentCents      = "settlement_sent_cents"
        case netPeerPositionCents     = "net_peer_position_cents"
    }

    public init(
        groupId: UUID,
        memberId: UUID,
        currency: String,
        stakeCents: Int64,
        stakeInKindCents: Int64,
        receivableCents: Int64,
        obligationCents: Int64,
        settlementReceivedCents: Int64,
        settlementSentCents: Int64,
        netPeerPositionCents: Int64
    ) {
        self.groupId = groupId
        self.memberId = memberId
        self.currency = currency
        self.stakeCents = stakeCents
        self.stakeInKindCents = stakeInKindCents
        self.receivableCents = receivableCents
        self.obligationCents = obligationCents
        self.settlementReceivedCents = settlementReceivedCents
        self.settlementSentCents = settlementSentCents
        self.netPeerPositionCents = netPeerPositionCents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId  = try c.decode(UUID.self, forKey: .groupId)
        self.memberId = try c.decode(UUID.self, forKey: .memberId)
        self.currency = try c.decode(String.self, forKey: .currency)
        self.stakeCents              = try Self.decodeCents(c, .stakeCents)
        self.stakeInKindCents        = try Self.decodeCents(c, .stakeInKindCents)
        self.receivableCents         = try Self.decodeCents(c, .receivableCents)
        self.obligationCents         = try Self.decodeCents(c, .obligationCents)
        self.settlementReceivedCents = try Self.decodeCents(c, .settlementReceivedCents)
        self.settlementSentCents     = try Self.decodeCents(c, .settlementSentCents)
        self.netPeerPositionCents    = try Self.decodeCents(c, .netPeerPositionCents)
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
