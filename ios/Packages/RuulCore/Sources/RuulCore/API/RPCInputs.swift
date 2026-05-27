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

    /// Emits every `p_*` key explicitly; nil Optionals encode as JSON
    /// `null`. The dev `record_expense` has REQUIRED positional args
    /// (no DEFAULT) for `p_resource_id`, so omitting the key breaks
    /// PostgREST overload resolution with "Could not find the function
    /// public.record_expense(...) in the schema cache". Founder lock
    /// §16-bis condition 3 mandates explicit null for shared-pool too.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encodeOrNil(pResourceId, forKey: .pResourceId)
        try c.encode(pAmount, forKey: .pAmount)
        try c.encode(pUnit, forKey: .pUnit)
        try c.encode(pPaidByMembershipId, forKey: .pPaidByMembershipId)
        try c.encodeOrNil(pDescription, forKey: .pDescription)
        try c.encode(pSplitMode, forKey: .pSplitMode)
        try c.encodeOrNil(pSplitBreakdown, forKey: .pSplitBreakdown)
        try c.encode(pInKind, forKey: .pInKind)
        try c.encodeOrNil(pMandateId, forKey: .pMandateId)
        try c.encodeOrNil(pClientId, forKey: .pClientId)
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

    /// See `RecordExpenseParams.encode(to:)` — same rationale: the dev
    /// `record_settlement` requires `p_paid_to_membership_id` even when
    /// `paid_to_kind = 'pool'`, so nil must serialise as JSON `null`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pPaidByMembershipId, forKey: .pPaidByMembershipId)
        try c.encodeOrNil(pPaidToMembershipId, forKey: .pPaidToMembershipId)
        try c.encode(pPaidToKind, forKey: .pPaidToKind)
        try c.encode(pAmount, forKey: .pAmount)
        try c.encode(pUnit, forKey: .pUnit)
        try c.encodeOrNil(pNotes, forKey: .pNotes)
        try c.encodeOrNil(pMandateId, forKey: .pMandateId)
        try c.encodeOrNil(pClientId, forKey: .pClientId)
    }
}

// MARK: - Helpers

extension KeyedEncodingContainer {
    /// Always emits the key. When `value` is `nil`, encodes JSON `null`
    /// (via `encodeNil`) rather than omitting the key. Used by canonical
    /// params whose backend signature treats omitted keys differently
    /// from explicit nulls.
    mutating func encodeOrNil<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
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

// MARK: - Members

public struct GroupMembersParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct GroupMembershipBoundaryParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

// MARK: - Profile

/// Params for `update_my_profile(p_display_name, p_username, p_avatar_url, p_bio)`.
/// Backend trims/lowercases the inputs; the repository pre-trims so the
/// wire payload is already canonical (avoids subtle ambiguity between
/// "user typed spaces" and "user cleared the field").
public struct UpdateMyProfileInput: Encodable, Sendable, Equatable {
    public let pDisplayName: String
    public let pUsername: String?
    public let pAvatarUrl: String?
    public let pBio: String?

    enum CodingKeys: String, CodingKey {
        case pDisplayName = "p_display_name"
        case pUsername = "p_username"
        case pAvatarUrl = "p_avatar_url"
        case pBio = "p_bio"
    }

    public init(
        pDisplayName: String,
        pUsername: String? = nil,
        pAvatarUrl: String? = nil,
        pBio: String? = nil
    ) {
        self.pDisplayName = pDisplayName
        self.pUsername = pUsername
        self.pAvatarUrl = pAvatarUrl
        self.pBio = pBio
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
