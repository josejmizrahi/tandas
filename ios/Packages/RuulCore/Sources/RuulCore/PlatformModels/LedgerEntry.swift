import Foundation

/// Money atom per OpenPlatform Taxonomy §2.E. Append-only ledger for every
/// monetary movement: expense, contribution, payout, fine_issued,
/// fine_paid, settlement, etc.
///
/// Balance projections derive from this table — never store balances
/// elsewhere. The history feed renders ledger entries alongside other
/// system_events.
///
/// Schema source: mig 00078. Decodes from `public.ledger_entries`.
public struct LedgerEntry: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let resourceId: UUID?
    public let type: String
    public let amountCents: Int64
    public let currency: String
    public let fromMemberId: UUID?
    public let toMemberId: UUID?
    public let metadata: JSONConfig
    public let occurredAt: Date
    public let recordedAt: Date
    public let recordedBy: UUID?

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        resourceId: UUID? = nil,
        type: String,
        amountCents: Int64,
        currency: String = "MXN",
        fromMemberId: UUID? = nil,
        toMemberId: UUID? = nil,
        metadata: JSONConfig = .object([:]),
        occurredAt: Date = .now,
        recordedAt: Date = .now,
        recordedBy: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.resourceId = resourceId
        self.type = type
        self.amountCents = amountCents
        self.currency = currency
        self.fromMemberId = fromMemberId
        self.toMemberId = toMemberId
        self.metadata = metadata
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.recordedBy = recordedBy
    }

    public enum CodingKeys: String, CodingKey {
        case id, type, currency, metadata
        case groupId      = "group_id"
        case resourceId   = "resource_id"
        case amountCents  = "amount_cents"
        case fromMemberId = "from_member_id"
        case toMemberId   = "to_member_id"
        case occurredAt   = "occurred_at"
        case recordedAt   = "recorded_at"
        case recordedBy   = "recorded_by"
    }

    /// Canonical ledger entry types per Taxonomy. String-typed for
    /// forward-compat — new types can land server-side without iOS
    /// pushes. Use these constants to avoid typos.
    public enum Kind {
        public static let expense       = "expense"
        public static let contribution  = "contribution"
        public static let payout        = "payout"
        public static let fineIssued    = "fine_issued"
        public static let finePaid      = "fine_paid"
        public static let settlement    = "settlement"
        public static let reimbursement = "reimbursement"
    }
}
