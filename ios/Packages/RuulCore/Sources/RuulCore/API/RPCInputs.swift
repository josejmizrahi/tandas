import Foundation

/// Encodable parameter structs — one per RPC the Foundation surface exposes.
/// Each property maps 1:1 to a `p_*` argument in the dev contract; `CodingKeys`
/// holds the snake_case wire form so the rest of RuulCore stays camelCase.
///
/// Reference: `Plans/Active/CanonicalRPCs_Contract.md` §2 (money) + §3 (identity)
/// + §13 (reads). UUIDs encode as lowercase strings via `Foundation.UUID`'s
/// default `Codable` behaviour.

// MARK: - Identity & Membership

public struct RPCCreateGroupParams: Encodable, Sendable {
    public let pName: String
    public let pSlug: String?
    public let pCategory: String?
    public let pPurposeDeclared: String?

    enum CodingKeys: String, CodingKey {
        case pName = "p_name"
        case pSlug = "p_slug"
        case pCategory = "p_category"
        case pPurposeDeclared = "p_purpose_declared"
    }

    public init(name: String, slug: String? = nil, category: String? = nil, purposeDeclared: String? = nil) {
        self.pName = name
        self.pSlug = slug
        self.pCategory = category
        self.pPurposeDeclared = purposeDeclared
    }
}

public struct InviteMemberParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pEmail: String?
    public let pPhone: String?
    public let pMembershipType: String
    public let pMessage: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pEmail = "p_email"
        case pPhone = "p_phone"
        case pMembershipType = "p_membership_type"
        case pMessage = "p_message"
    }

    public init(groupId: UUID, email: String? = nil, phone: String? = nil, membershipType: String = "member", message: String? = nil) {
        self.pGroupId = groupId
        self.pEmail = email
        self.pPhone = phone
        self.pMembershipType = membershipType
        self.pMessage = message
    }
}

public struct AcceptInviteParams: Encodable, Sendable {
    public let pCode: String
    enum CodingKeys: String, CodingKey { case pCode = "p_code" }
    public init(code: String) { self.pCode = code }
}

public struct LeaveGroupParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pReason: String?
    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pReason = "p_reason"
    }
    public init(groupId: UUID, reason: String? = nil) {
        self.pGroupId = groupId
        self.pReason = reason
    }
}

// MARK: - Money

public struct RecordExpenseParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pResourceId: UUID?           // nullable — null = shared pool
    public let pAmount: Decimal
    public let pUnit: String
    public let pPaidByMembershipId: UUID
    public let pDescription: String?
    public let pSplitMode: String
    public let pSplitBreakdown: [SplitShare]?
    public let pInKind: Bool
    public let pMandateId: UUID?
    public let pClientId: String?

    public struct SplitShare: Encodable, Sendable, Equatable {
        public let membershipId: UUID
        public let amount: Decimal
        enum CodingKeys: String, CodingKey {
            case membershipId = "membership_id"
            case amount
        }
        public init(membershipId: UUID, amount: Decimal) {
            self.membershipId = membershipId
            self.amount = amount
        }
    }

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pResourceId = "p_resource_id"
        case pAmount = "p_amount"
        case pUnit = "p_unit"
        case pPaidByMembershipId = "p_paid_by_membership_id"
        case pDescription = "p_description"
        case pSplitMode = "p_split_mode"
        case pSplitBreakdown = "p_split_breakdown"
        case pInKind = "p_in_kind"
        case pMandateId = "p_mandate_id"
        case pClientId = "p_client_id"
    }

    /// Convenience init from a domain draft. Foundation always sends
    /// `p_mandate_id = nil` (Foundation scope = self_party only; mandates
    /// land in a later phase).
    public init(draft: ExpenseDraft, clientId: String?) {
        self.pGroupId = draft.groupId
        self.pResourceId = draft.resourceId
        self.pAmount = draft.amount
        self.pUnit = draft.currency.rawValue
        self.pPaidByMembershipId = draft.paidByMembershipId
        self.pDescription = draft.description
        self.pSplitMode = draft.split.rpcMode
        self.pSplitBreakdown = {
            if case .custom(let shares) = draft.split {
                return shares.map { SplitShare(membershipId: $0.membershipId, amount: $0.amount) }
            }
            return nil
        }()
        self.pInKind = draft.inKind
        self.pMandateId = nil
        self.pClientId = clientId
    }
}

public struct RecordSettlementParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pPaidByMembershipId: UUID
    public let pPaidToMembershipId: UUID?    // null when paid_to_kind = pool
    public let pPaidToKind: String
    public let pAmount: Decimal
    public let pUnit: String
    public let pNotes: String?
    public let pMandateId: UUID?
    public let pClientId: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pPaidByMembershipId = "p_paid_by_membership_id"
        case pPaidToMembershipId = "p_paid_to_membership_id"
        case pPaidToKind = "p_paid_to_kind"
        case pAmount = "p_amount"
        case pUnit = "p_unit"
        case pNotes = "p_notes"
        case pMandateId = "p_mandate_id"
        case pClientId = "p_client_id"
    }

    public init(draft: SettlementDraft, clientId: String?) {
        self.pGroupId = draft.groupId
        self.pPaidByMembershipId = draft.paidByMembershipId
        self.pPaidToMembershipId = draft.target.paidToMembershipId
        self.pPaidToKind = draft.target.paidToKind
        self.pAmount = draft.amount
        self.pUnit = draft.currency.rawValue
        self.pNotes = draft.notes
        self.pMandateId = nil
        self.pClientId = clientId
    }
}

// MARK: - Reads

public struct GroupSummaryParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct MemberBalanceParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pMembershipId: UUID
    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pMembershipId = "p_membership_id"
    }
    public init(groupId: UUID, membershipId: UUID) {
        self.pGroupId = groupId
        self.pMembershipId = membershipId
    }
}

public struct MemberObligationSummaryParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pMembershipId: UUID
    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pMembershipId = "p_membership_id"
    }
    public init(groupId: UUID, membershipId: UUID) {
        self.pGroupId = groupId
        self.pMembershipId = membershipId
    }
}

public struct ListMemberPermissionsParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pUserId: UUID?
    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pUserId = "p_user_id"
    }
    public init(groupId: UUID, userId: UUID? = nil) {
        self.pGroupId = groupId
        self.pUserId = userId
    }
}
