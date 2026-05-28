import Foundation

/// Currency identifier as stored in `group_resource_transactions.unit`.
/// V1 is MXN-only; V2 will derive from `groups.settings.default_unit`.
public struct CurrencyCode: Sendable, Hashable, RawRepresentable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }

    public static let mxn = CurrencyCode(rawValue: "MXN")
}

/// How to split a recorded expense across the group.
public enum ExpenseSplit: Sendable, Equatable {
    case even
    case custom(breakdown: [Share])

    public struct Share: Sendable, Equatable {
        public let membershipId: UUID
        public let amount: Decimal
        public init(membershipId: UUID, amount: Decimal) {
            self.membershipId = membershipId
            self.amount = amount
        }
    }

    public var rpcMode: String {
        switch self {
        case .even: return "even"
        case .custom: return "custom"
        }
    }
}

/// User-facing draft of an expense before it hits `record_expense`.
public struct ExpenseDraft: Sendable, Equatable {
    public let groupId: UUID
    public let resourceId: UUID?           // nil = shared pool (doctrine_shared_money)
    public let amount: Decimal
    public let currency: CurrencyCode
    public let paidByMembershipId: UUID
    public let description: String?
    public let split: ExpenseSplit
    public let inKind: Bool
    /// V2-G5 — when set, the caller is recording the expense on
    /// behalf of someone they hold a mandate from. Persists to
    /// `transactions.mandate_id` for audit; null = acting in their
    /// own name.
    public let mandateId: UUID?

    public init(
        groupId: UUID,
        resourceId: UUID? = nil,
        amount: Decimal,
        currency: CurrencyCode = .mxn,
        paidByMembershipId: UUID,
        description: String? = nil,
        split: ExpenseSplit = .even,
        inKind: Bool = false,
        mandateId: UUID? = nil
    ) {
        self.groupId = groupId
        self.resourceId = resourceId
        self.amount = amount
        self.currency = currency
        self.paidByMembershipId = paidByMembershipId
        self.description = description
        self.split = split
        self.inKind = inKind
        self.mandateId = mandateId
    }
}

/// Who the settlement is being paid to.
public enum SettlementTarget: Sendable, Equatable {
    case member(membershipId: UUID)
    case pool

    public var paidToKind: String {
        switch self {
        case .member: return "member"
        case .pool: return "pool"
        }
    }

    public var paidToMembershipId: UUID? {
        if case .member(let id) = self { return id }
        return nil
    }
}

/// User-facing draft of a settlement before it hits `record_settlement`.
public struct SettlementDraft: Sendable, Equatable {
    public let groupId: UUID
    public let paidByMembershipId: UUID
    public let target: SettlementTarget
    public let amount: Decimal
    public let currency: CurrencyCode
    public let notes: String?
    /// V2-G5 — see `ExpenseDraft.mandateId`. Both sides share the
    /// same `p_mandate_id` plumbing on the RPC.
    public let mandateId: UUID?

    public init(
        groupId: UUID,
        paidByMembershipId: UUID,
        target: SettlementTarget,
        amount: Decimal,
        currency: CurrencyCode = .mxn,
        notes: String? = nil,
        mandateId: UUID? = nil
    ) {
        self.groupId = groupId
        self.paidByMembershipId = paidByMembershipId
        self.target = target
        self.amount = amount
        self.currency = currency
        self.notes = notes
        self.mandateId = mandateId
    }
}

/// One open obligation row as returned by `member_obligation_summary`.
public struct ObligationSummary: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: String
    public let amountOutstanding: Decimal
    public let owedToKind: String
    /// Counterparty membership id when `owedToKind == "member"`; nil when
    /// `owedToKind == "pool"`. Exposed in canonical_followup_25 so iOS
    /// can pre-fill `record_settlement.p_paid_to_membership_id` when
    /// settling member-to-member.
    public let owedToMembershipId: UUID?
    public let owedToLabel: String

    public init(
        id: UUID,
        kind: String,
        amountOutstanding: Decimal,
        owedToKind: String,
        owedToMembershipId: UUID?,
        owedToLabel: String
    ) {
        self.id = id
        self.kind = kind
        self.amountOutstanding = amountOutstanding
        self.owedToKind = owedToKind
        self.owedToMembershipId = owedToMembershipId
        self.owedToLabel = owedToLabel
    }
}
