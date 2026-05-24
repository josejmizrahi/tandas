import Foundation

/// Projection: one row of `public.member_balances_per_group` (mig 00136).
/// Per `(group_id, member_id, currency)` rollup of every ledger entry
/// where the member is either the sender (`from_member_id`) or the
/// receiver (`to_member_id`).
///
/// Net interpretation (SharedMoney P3):
/// - `netCents > 0`: the group "owes" this member — they've put more
///   into the system than they've taken out. Surface as "Te deben".
/// - `netCents < 0`: the member is "out of pocket" net — they've
///   received more than they've sent (typical after a reimbursement
///   round where they took payouts but not yet paid their share).
///   Surface as "Tu situación: pendiente de cuadrar".
///
/// Caveat: the view aggregates ALL ledger types (contribution, expense
/// reimbursement, settlement, payout, fines). For Splitwise-style
/// pairwise "X le debe a Y", a richer projection is needed — P3 V1
/// keeps the single-net interpretation.
public struct MemberGroupBalance: Projection, Identifiable, Hashable, Sendable {
    public static var projectionViewName: String { "member_balances_per_group" }

    public let groupId: UUID
    public let memberId: UUID
    public let currency: String
    public let sentCents: Int64
    public let receivedCents: Int64
    public let netCents: Int64

    public var id: String { "\(groupId.uuidString)|\(memberId.uuidString)|\(currency)" }

    /// True when this member is owed money (net positive). UI shows
    /// the green "Te deben" surface.
    public var isOwed: Bool { netCents > 0 }

    /// True when this member owes the group net. UI shows "Debes" copy.
    public var isInDebt: Bool { netCents < 0 }

    /// True when the member is at zero — no surface needed (Apple-
    /// like: don't add noise for the steady state).
    public var isSettled: Bool { netCents == 0 }

    public enum CodingKeys: String, CodingKey {
        case groupId        = "group_id"
        case memberId       = "member_id"
        case currency
        case sentCents      = "sent_cents"
        case receivedCents  = "received_cents"
        case netCents       = "net_cents"
    }

    public init(
        groupId: UUID,
        memberId: UUID,
        currency: String,
        sentCents: Int64,
        receivedCents: Int64,
        netCents: Int64
    ) {
        self.groupId = groupId
        self.memberId = memberId
        self.currency = currency
        self.sentCents = sentCents
        self.receivedCents = receivedCents
        self.netCents = netCents
    }

    /// The view declares `sent_cents` / `received_cents` / `net_cents`
    /// as `numeric` (sum of bigint). PostgREST serializes numeric as a
    /// JSON string by default to preserve precision, so we can't just
    /// decode to Int64 directly. This custom init accepts both forms
    /// (string or number) and converts to Int64 — the values are
    /// integer cents, so no precision loss.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId  = try c.decode(UUID.self, forKey: .groupId)
        self.memberId = try c.decode(UUID.self, forKey: .memberId)
        self.currency = try c.decode(String.self, forKey: .currency)
        self.sentCents     = try Self.decodeCents(from: c, key: .sentCents)
        self.receivedCents = try Self.decodeCents(from: c, key: .receivedCents)
        self.netCents      = try Self.decodeCents(from: c, key: .netCents)
    }

    private static func decodeCents(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64 {
        if let i = try? container.decode(Int64.self, forKey: key) { return i }
        if let s = try? container.decode(String.self, forKey: key),
           let i = Int64(s) {
            return i
        }
        if let d = try? container.decode(Double.self, forKey: key) {
            return Int64(d)
        }
        return 0
    }
}
