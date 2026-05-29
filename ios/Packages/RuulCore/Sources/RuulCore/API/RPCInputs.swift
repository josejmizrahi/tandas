import Foundation

/// Encodable parameter structs — one per RPC the Foundation surface exposes.
/// Each property maps 1:1 to a `p_*` argument in the dev contract; `CodingKeys`
/// holds the snake_case wire form so the rest of RuulCore stays camelCase.
///
/// Reference: `Plans/Active/CanonicalRPCs_Contract.md` §2 (money) + §3 (identity)
/// + §13 (reads). UUIDs encode as lowercase strings via `Foundation.UUID`'s
/// default `Codable` behaviour.

/// V2-G9 — minimal JSON value container used by RPC params that need to
/// pass nested jsonb (e.g. `start_vote.p_metadata.weight_strategy`).
/// Flat string maps keep working via the `.string` case.
/// V2-G3.1 — added `.array` + `Decodable` so engine-rule round-trips
/// (`condition_tree.fields`, `consequences[].fields`) can decode the
/// catalog-driven payload back from `group_rules_engine(...)`.
public indirect enum RPCJSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case array([RPCJSONValue])
    case object([String: RPCJSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null:          try c.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        // Decimal must be tried before String — JSONDecoder will happily
        // decode `"42"` (string) as Decimal otherwise on some platforms.
        if let n = try? c.decode(Decimal.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([RPCJSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: RPCJSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported jsonb leaf value"
        )
    }
}

public extension Dictionary where Key == String, Value == String {
    /// Lift a flat `[String: String]` into the typed `RPCJSONValue`
    /// container. Used by callers that only need leaf string values.
    var asRPCMetadata: [String: RPCJSONValue] {
        Dictionary<String, RPCJSONValue>(uniqueKeysWithValues:
            self.map { ($0.key, .string($0.value)) }
        )
    }
}

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

    /// Convenience init from a domain draft. Mandate-on-behalf-of is
    /// V2-G5 wiring: `p_mandate_id` is populated from the draft when
    /// the actor is acting under an active mandate; null otherwise.
    ///
    /// V3-S1: both `.even` and `.custom` materialise to wire-level
    /// `p_split_mode = "custom"` with an explicit per-participant
    /// breakdown. For `.even` we run `ExpenseSplitCalculator.even(...)`
    /// so leftover cents land deterministically client-side; the server
    /// then takes the exact sums and skips its own 4-decimal rounding
    /// path (which would otherwise drift on totals like $100/3 and
    /// silently lose a fraction of a cent).
    public init(draft: ExpenseDraft, clientId: String?) {
        self.pGroupId = draft.groupId
        self.pResourceId = draft.resourceId
        self.pAmount = draft.amount
        self.pUnit = draft.currency.rawValue
        self.pPaidByMembershipId = draft.paidByMembershipId
        self.pDescription = draft.description
        self.pSplitMode = draft.split.rpcMode
        self.pSplitBreakdown = {
            switch draft.split {
            case .even(let participantIds):
                guard !participantIds.isEmpty else { return nil }
                let shares = ExpenseSplitCalculator.even(
                    amount: draft.amount,
                    participants: participantIds
                )
                return shares.map { SplitShare(membershipId: $0.membershipId, amount: $0.amount) }
            case .custom(let shares):
                return shares.map { SplitShare(membershipId: $0.membershipId, amount: $0.amount) }
            }
        }()
        self.pInKind = draft.inKind
        self.pMandateId = draft.mandateId
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
        self.pMandateId = draft.mandateId
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

// MARK: - Purpose

public struct GroupPurposesActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct SetGroupPurposeInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pKind: String
    public let pBody: String
    public let pVisibility: String

    enum CodingKeys: String, CodingKey {
        case pGroupId    = "p_group_id"
        case pKind       = "p_kind"
        case pBody       = "p_body"
        case pVisibility = "p_visibility"
    }

    public init(pGroupId: UUID, pKind: String, pBody: String, pVisibility: String) {
        self.pGroupId = pGroupId
        self.pKind = pKind
        self.pBody = pBody
        self.pVisibility = pVisibility
    }
}

// MARK: - Rules

public struct GroupRulesActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct CreateTextRuleInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pTitle: String
    public let pBody: String
    public let pRuleType: String
    public let pSeverity: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId  = "p_group_id"
        case pTitle    = "p_title"
        case pBody     = "p_body"
        case pRuleType = "p_rule_type"
        case pSeverity = "p_severity"
    }

    public init(pGroupId: UUID, pTitle: String, pBody: String, pRuleType: String, pSeverity: Int) {
        self.pGroupId = pGroupId
        self.pTitle = pTitle
        self.pBody = pBody
        self.pRuleType = pRuleType
        self.pSeverity = pSeverity
    }
}

public struct ArchiveRuleInput: Encodable, Sendable, Equatable {
    public let pRuleId: UUID
    public let pReason: String?

    enum CodingKeys: String, CodingKey {
        case pRuleId = "p_rule_id"
        case pReason = "p_reason"
    }

    public init(pRuleId: UUID, pReason: String? = nil) {
        self.pRuleId = pRuleId
        self.pReason = pReason
    }
}

// MARK: - Rule engine (V2-G3.1)

public struct GroupRulesEngineParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

/// jsonb payload passed to `validate_rule_shape(p_shape jsonb)` and
/// embedded by `create_engine_rule(...)` for server-side validation.
public struct RuleShapePayload: Codable, Sendable, Equatable, Hashable {
    public let shapeKey: String
    public let conditionTree: EngineRuleCondition?
    public let consequences: [EngineRuleConsequence]

    enum CodingKeys: String, CodingKey {
        case shapeKey      = "shape_key"
        case conditionTree = "condition_tree"
        case consequences
    }

    public init(
        shapeKey: String,
        conditionTree: EngineRuleCondition? = nil,
        consequences: [EngineRuleConsequence] = []
    ) {
        self.shapeKey = shapeKey
        self.conditionTree = conditionTree
        self.consequences = consequences
    }
}

public struct ValidateRuleShapeInput: Encodable, Sendable, Equatable {
    public let pShape: RuleShapePayload
    enum CodingKeys: String, CodingKey { case pShape = "p_shape" }
    public init(shape: RuleShapePayload) { self.pShape = shape }
}

public struct GroupRuleEvaluationsParams: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pLimit: Int
    public let pBefore: Date?

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pLimit   = "p_limit"
        case pBefore  = "p_before"
    }

    public init(groupId: UUID, limit: Int = 50, before: Date? = nil) {
        self.pGroupId = groupId
        self.pLimit = limit
        self.pBefore = before
    }
}

public struct GroupRuleEvaluationSummaryParams: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pWindowHours: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId     = "p_group_id"
        case pWindowHours = "p_window_hours"
    }

    public init(groupId: UUID, windowHours: Int = 24) {
        self.pGroupId = groupId
        self.pWindowHours = windowHours
    }
}

public struct SystemEventEngineProvenanceParams: Encodable, Sendable, Equatable {
    public let pEventUuidId: UUID

    enum CodingKeys: String, CodingKey {
        case pEventUuidId = "p_event_uuid_id"
    }

    public init(eventUuid: UUID) {
        self.pEventUuidId = eventUuid
    }
}

public struct GroupSanctionPaymentStatusParams: Encodable, Sendable, Equatable {
    public let pSanctionId: UUID

    enum CodingKeys: String, CodingKey {
        case pSanctionId = "p_sanction_id"
    }

    public init(sanctionId: UUID) {
        self.pSanctionId = sanctionId
    }
}

public struct ProposeSanctionPaymentPlanParams: Encodable, Sendable, Equatable {
    public let pSanctionId: UUID
    public let pInstallments: Int
    public let pFirstDueAt: Date
    public let pIntervalDays: Int
    public let pNotes: String?

    enum CodingKeys: String, CodingKey {
        case pSanctionId   = "p_sanction_id"
        case pInstallments = "p_installments"
        case pFirstDueAt   = "p_first_due_at"
        case pIntervalDays = "p_interval_days"
        case pNotes        = "p_notes"
    }

    public init(sanctionId: UUID, installments: Int, firstDueAt: Date, intervalDays: Int = 30, notes: String? = nil) {
        self.pSanctionId = sanctionId
        self.pInstallments = installments
        self.pFirstDueAt = firstDueAt
        self.pIntervalDays = intervalDays
        self.pNotes = notes
    }
}

public struct CancelSanctionPaymentPlanParams: Encodable, Sendable, Equatable {
    public let pPlanId: UUID
    public let pReason: String?

    enum CodingKeys: String, CodingKey {
        case pPlanId = "p_plan_id"
        case pReason = "p_reason"
    }

    public init(planId: UUID, reason: String? = nil) {
        self.pPlanId = planId
        self.pReason = reason
    }
}

public struct CreateEngineRuleInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pTitle: String
    public let pShapeKey: String
    public let pConditionTree: EngineRuleCondition?
    public let pConsequences: [EngineRuleConsequence]
    public let pRuleType: String
    public let pSeverity: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId       = "p_group_id"
        case pTitle         = "p_title"
        case pShapeKey      = "p_shape_key"
        case pConditionTree = "p_condition_tree"
        case pConsequences  = "p_consequences"
        case pRuleType      = "p_rule_type"
        case pSeverity      = "p_severity"
    }

    public init(
        pGroupId: UUID,
        pTitle: String,
        pShapeKey: String,
        pConditionTree: EngineRuleCondition?,
        pConsequences: [EngineRuleConsequence],
        pRuleType: String = "norm",
        pSeverity: Int = 1
    ) {
        self.pGroupId = pGroupId
        self.pTitle = pTitle
        self.pShapeKey = pShapeKey
        self.pConditionTree = pConditionTree
        self.pConsequences = pConsequences
        self.pRuleType = pRuleType
        self.pSeverity = pSeverity
    }
}

// MARK: - Resources

public struct GroupResourcesActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct CreateGroupResourceInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pResourceType: String
    public let pName: String
    public let pDescription: String?
    public let pVisibility: String
    public let pOwnershipKind: String
    public let pOwnerMembershipId: UUID?
    public let pCustodianMembershipId: UUID?

    enum CodingKeys: String, CodingKey {
        case pGroupId               = "p_group_id"
        case pResourceType          = "p_resource_type"
        case pName                  = "p_name"
        case pDescription           = "p_description"
        case pVisibility            = "p_visibility"
        case pOwnershipKind         = "p_ownership_kind"
        case pOwnerMembershipId     = "p_owner_membership_id"
        case pCustodianMembershipId = "p_custodian_membership_id"
    }

    public init(
        pGroupId: UUID,
        pResourceType: String,
        pName: String,
        pDescription: String? = nil,
        pVisibility: String = "members",
        pOwnershipKind: String = "group",
        pOwnerMembershipId: UUID? = nil,
        pCustodianMembershipId: UUID? = nil
    ) {
        self.pGroupId = pGroupId
        self.pResourceType = pResourceType
        self.pName = pName
        self.pDescription = pDescription
        self.pVisibility = pVisibility
        self.pOwnershipKind = pOwnershipKind
        self.pOwnerMembershipId = pOwnerMembershipId
        self.pCustodianMembershipId = pCustodianMembershipId
    }
}

public struct ArchiveGroupResourceInput: Encodable, Sendable, Equatable {
    public let pResourceId: UUID
    public let pReason: String?

    enum CodingKeys: String, CodingKey {
        case pResourceId = "p_resource_id"
        case pReason     = "p_reason"
    }

    public init(pResourceId: UUID, pReason: String? = nil) {
        self.pResourceId = pResourceId
        self.pReason = pReason
    }
}

// MARK: - Foundation status

public struct GroupFoundationStatusParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

// MARK: - History / Events (Primitiva 13)

public struct GroupEventsRecentParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pLimit: Int
    public let pBefore: Date?

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pLimit   = "p_limit"
        case pBefore  = "p_before"
    }

    public init(groupId: UUID, limit: Int = 100, before: Date? = nil) {
        self.pGroupId = groupId
        self.pLimit = limit
        self.pBefore = before
    }

    /// Emit `p_before` as JSON `null` when nil so PostgREST overload
    /// resolution stays deterministic.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pLimit, forKey: .pLimit)
        try c.encodeOrNil(pBefore, forKey: .pBefore)
    }
}

// MARK: - Money movements (Primitiva 19, A2.b)

public struct GroupMoneyMovementsParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pLimit: Int
    public let pFilter: [String]?
    public let pBeforeSeq: Int64?

    enum CodingKeys: String, CodingKey {
        case pGroupId   = "p_group_id"
        case pLimit     = "p_limit"
        case pFilter    = "p_filter"
        case pBeforeSeq = "p_before_seq"
    }

    public init(groupId: UUID, limit: Int = 100, filter: [String]? = nil, beforeSeq: Int64? = nil) {
        self.pGroupId = groupId
        self.pLimit = limit
        self.pFilter = filter
        self.pBeforeSeq = beforeSeq
    }

    /// Emit `null` for optional cursor + filter so PostgREST overload
    /// resolution stays deterministic.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pLimit, forKey: .pLimit)
        try c.encodeOrNil(pFilter, forKey: .pFilter)
        try c.encodeOrNil(pBeforeSeq, forKey: .pBeforeSeq)
    }
}

// MARK: - Reputation (Primitiva 12, C4)

public struct GroupReputationEventsParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pLimit   = "p_limit"
    }

    public init(groupId: UUID, limit: Int = 100) {
        self.pGroupId = groupId
        self.pLimit = limit
    }
}

public struct RecordReputationEventParams: Encodable, Sendable, Equatable, Hashable {
    public let pGroupId: UUID
    public let pSubjectMembershipId: UUID
    public let pReputationType: String
    public let pReason: String?
    public let pVisibility: String

    enum CodingKeys: String, CodingKey {
        case pGroupId              = "p_group_id"
        case pSubjectMembershipId  = "p_subject_membership_id"
        case pReputationType       = "p_reputation_type"
        case pReason               = "p_reason"
        case pVisibility           = "p_visibility"
    }

    public init(
        groupId: UUID,
        subjectMembershipId: UUID,
        reputationType: String,
        reason: String? = nil,
        visibility: String = "members"
    ) {
        self.pGroupId = groupId
        self.pSubjectMembershipId = subjectMembershipId
        self.pReputationType = reputationType
        self.pReason = reason
        self.pVisibility = visibility
    }

    /// Emit `null` for `p_reason` when nil so PostgREST overload
    /// resolution stays deterministic. evidence + metadata are not
    /// surfaced in Foundation; backend defaults handle them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pSubjectMembershipId, forKey: .pSubjectMembershipId)
        try c.encode(pReputationType, forKey: .pReputationType)
        try c.encodeOrNil(pReason, forKey: .pReason)
        try c.encode(pVisibility, forKey: .pVisibility)
    }
}

// MARK: - Contributions (Primitiva 9, C3)

public struct GroupContributionsActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pMembershipId: UUID?
    public let pResourceId: UUID?

    enum CodingKeys: String, CodingKey {
        case pGroupId      = "p_group_id"
        case pMembershipId = "p_membership_id"
        case pResourceId   = "p_resource_id"
    }

    public init(groupId: UUID, membershipId: UUID? = nil, resourceId: UUID? = nil) {
        self.pGroupId = groupId
        self.pMembershipId = membershipId
        self.pResourceId = resourceId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encodeOrNil(pMembershipId, forKey: .pMembershipId)
        try c.encodeOrNil(pResourceId, forKey: .pResourceId)
    }
}

public struct LogContributionParams: Encodable, Sendable, Equatable, Hashable {
    public let pGroupId: UUID
    public let pContributionType: String
    public let pTitle: String?
    public let pDescription: String?
    public let pAmount: Decimal?
    public let pUnit: String?
    public let pSourceResourceId: UUID?
    public let pOccurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case pGroupId          = "p_group_id"
        case pContributionType = "p_contribution_type"
        case pTitle            = "p_title"
        case pDescription      = "p_description"
        case pAmount           = "p_amount"
        case pUnit             = "p_unit"
        case pSourceResourceId = "p_source_resource_id"
        case pOccurredAt       = "p_occurred_at"
    }

    public init(
        groupId: UUID,
        contributionType: String,
        title: String? = nil,
        description: String? = nil,
        amount: Decimal? = nil,
        unit: String? = nil,
        sourceResourceId: UUID? = nil,
        occurredAt: Date? = nil
    ) {
        self.pGroupId = groupId
        self.pContributionType = contributionType
        self.pTitle = title
        self.pDescription = description
        self.pAmount = amount
        self.pUnit = unit
        self.pSourceResourceId = sourceResourceId
        self.pOccurredAt = occurredAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pContributionType, forKey: .pContributionType)
        try c.encodeOrNil(pTitle, forKey: .pTitle)
        try c.encodeOrNil(pDescription, forKey: .pDescription)
        try c.encodeOrNil(pAmount, forKey: .pAmount)
        try c.encodeOrNil(pUnit, forKey: .pUnit)
        try c.encodeOrNil(pSourceResourceId, forKey: .pSourceResourceId)
        try c.encodeOrNil(pOccurredAt, forKey: .pOccurredAt)
    }
}

public struct SetMembershipStateParams: Encodable, Sendable, Equatable, Hashable {
    public let pMembershipId: UUID
    public let pNewState: String
    public let pReason: String?
    public let pUntil: Date?

    enum CodingKeys: String, CodingKey {
        case pMembershipId = "p_membership_id"
        case pNewState     = "p_new_state"
        case pReason       = "p_reason"
        case pUntil        = "p_until"
    }

    public init(
        membershipId: UUID,
        newState: String,
        reason: String? = nil,
        until: Date? = nil
    ) {
        self.pMembershipId = membershipId
        self.pNewState = newState
        self.pReason = reason
        self.pUntil = until
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pMembershipId, forKey: .pMembershipId)
        try c.encode(pNewState, forKey: .pNewState)
        try c.encodeOrNil(pReason, forKey: .pReason)
        try c.encodeOrNil(pUntil, forKey: .pUntil)
    }
}

public struct SetResourceOwnershipParams: Encodable, Sendable, Equatable, Hashable {
    public let pResourceId: UUID
    public let pOwnershipKind: String
    public let pOwnerMembershipId: UUID?
    public let pMetadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case pResourceId        = "p_resource_id"
        case pOwnershipKind     = "p_ownership_kind"
        case pOwnerMembershipId = "p_owner_membership_id"
        case pMetadata          = "p_metadata"
    }

    public init(
        resourceId: UUID,
        ownershipKind: String,
        ownerMembershipId: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.pResourceId = resourceId
        self.pOwnershipKind = ownershipKind
        self.pOwnerMembershipId = ownerMembershipId
        self.pMetadata = metadata
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pResourceId, forKey: .pResourceId)
        try c.encode(pOwnershipKind, forKey: .pOwnershipKind)
        try c.encodeOrNil(pOwnerMembershipId, forKey: .pOwnerMembershipId)
        try c.encode(pMetadata, forKey: .pMetadata)
    }
}

public struct VerifyContributionParams: Encodable, Sendable, Equatable, Hashable {
    public let pContributionId: UUID
    public let pOutcome: String
    public let pNote: String?

    enum CodingKeys: String, CodingKey {
        case pContributionId = "p_contribution_id"
        case pOutcome        = "p_outcome"
        case pNote           = "p_note"
    }

    public init(contributionId: UUID, outcome: String, note: String? = nil) {
        self.pContributionId = contributionId
        self.pOutcome = outcome
        self.pNote = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pContributionId, forKey: .pContributionId)
        try c.encode(pOutcome, forKey: .pOutcome)
        try c.encodeOrNil(pNote, forKey: .pNote)
    }
}

// MARK: - Mandates (Primitiva 23, B4)

public struct GroupMandatesActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct GrantMandateParams: Encodable, Sendable, Equatable, Hashable {
    public let pGroupId: UUID
    public let pRepresentativeMembershipId: UUID
    public let pMandateType: String
    public let pPrincipalType: String
    public let pPrincipalId: UUID?
    public let pEndsAt: Date?

    enum CodingKeys: String, CodingKey {
        case pGroupId                    = "p_group_id"
        case pRepresentativeMembershipId = "p_representative_membership_id"
        case pMandateType                = "p_mandate_type"
        case pPrincipalType              = "p_principal_type"
        case pPrincipalId                = "p_principal_id"
        case pEndsAt                     = "p_ends_at"
    }

    public init(
        groupId: UUID,
        representativeMembershipId: UUID,
        mandateType: String,
        principalType: String = "group",
        principalId: UUID? = nil,
        endsAt: Date? = nil
    ) {
        self.pGroupId = groupId
        self.pRepresentativeMembershipId = representativeMembershipId
        self.pMandateType = mandateType
        self.pPrincipalType = principalType
        self.pPrincipalId = principalId
        self.pEndsAt = endsAt
    }

    /// Emit `null` for optional principal_id + ends_at so PostgREST
    /// overload resolution stays deterministic. We don't expose
    /// `p_scope` or `p_source_decision_id` from Foundation — they
    /// default at the backend.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pRepresentativeMembershipId, forKey: .pRepresentativeMembershipId)
        try c.encode(pMandateType, forKey: .pMandateType)
        try c.encode(pPrincipalType, forKey: .pPrincipalType)
        try c.encodeOrNil(pPrincipalId, forKey: .pPrincipalId)
        try c.encodeOrNil(pEndsAt, forKey: .pEndsAt)
    }
}

public struct RevokeMandateParams: Encodable, Sendable, Equatable, Hashable {
    public let pMandateId: UUID
    public let pReason: String?
    enum CodingKeys: String, CodingKey {
        case pMandateId = "p_mandate_id"
        case pReason    = "p_reason"
    }
    public init(mandateId: UUID, reason: String? = nil) {
        self.pMandateId = mandateId
        self.pReason = reason
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pMandateId, forKey: .pMandateId)
        try c.encodeOrNil(pReason, forKey: .pReason)
    }
}

// MARK: - Cultural norms (Primitiva 20, B5)

public struct GroupCulturalNormsActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct ProposeCulturalNormParams: Encodable, Sendable, Equatable, Hashable {
    public let pGroupId: UUID
    public let pNormType: String
    public let pTitle: String
    public let pBody: String?
    public let pVisibility: String

    enum CodingKeys: String, CodingKey {
        case pGroupId   = "p_group_id"
        case pNormType  = "p_norm_type"
        case pTitle     = "p_title"
        case pBody      = "p_body"
        case pVisibility = "p_visibility"
    }

    public init(
        groupId: UUID,
        normType: String,
        title: String,
        body: String? = nil,
        visibility: String = "members"
    ) {
        self.pGroupId = groupId
        self.pNormType = normType
        self.pTitle = title
        self.pBody = body
        self.pVisibility = visibility
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pNormType, forKey: .pNormType)
        try c.encode(pTitle, forKey: .pTitle)
        try c.encodeOrNil(pBody, forKey: .pBody)
        try c.encode(pVisibility, forKey: .pVisibility)
    }
}

public struct EndorseCulturalNormParams: Encodable, Sendable {
    public let pNormId: UUID
    enum CodingKeys: String, CodingKey { case pNormId = "p_norm_id" }
    public init(normId: UUID) { self.pNormId = normId }
}

public struct RetireCulturalNormParams: Encodable, Sendable, Equatable, Hashable {
    public let pNormId: UUID
    public let pReason: String?
    enum CodingKeys: String, CodingKey {
        case pNormId = "p_norm_id"
        case pReason = "p_reason"
    }
    public init(normId: UUID, reason: String? = nil) {
        self.pNormId = normId
        self.pReason = reason
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pNormId, forKey: .pNormId)
        try c.encodeOrNil(pReason, forKey: .pReason)
    }
}

public struct PromoteNormToRuleInput: Encodable, Sendable, Equatable, Hashable {
    public let pNormId: UUID
    public let pRuleType: String
    public let pSeverity: Int

    enum CodingKeys: String, CodingKey {
        case pNormId   = "p_norm_id"
        case pRuleType = "p_rule_type"
        case pSeverity = "p_severity"
    }

    public init(normId: UUID, ruleType: String = "norm", severity: Int = 1) {
        self.pNormId = normId
        self.pRuleType = ruleType
        self.pSeverity = severity
    }
}

// MARK: - Disputes (Primitiva 14)

public struct GroupDisputesActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pLimit   = "p_limit"
    }

    public init(groupId: UUID, limit: Int = 50) {
        self.pGroupId = groupId
        self.pLimit = limit
    }
}

public struct DisputeSanctionInput: Encodable, Sendable, Equatable {
    public let pSanctionId: UUID
    public let pSummary: String

    enum CodingKeys: String, CodingKey {
        case pSanctionId = "p_sanction_id"
        case pSummary    = "p_summary"
    }

    public init(pSanctionId: UUID, pSummary: String) {
        self.pSanctionId = pSanctionId
        self.pSummary = pSummary
    }
}

// MARK: - Notifications + Privacy (B7)

public struct MyNotificationPreferencesParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct RegisterMyNotificationTokenInput: Encodable, Sendable, Equatable {
    public let pToken: String
    public let pPlatform: String

    enum CodingKeys: String, CodingKey {
        case pToken    = "p_token"
        case pPlatform = "p_platform"
    }

    public init(token: String, platform: String = "ios") {
        self.pToken = token
        self.pPlatform = platform
    }
}

public struct SetNotificationPreferenceInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pCategory: String
    public let pChannel: String
    public let pEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case pGroupId  = "p_group_id"
        case pCategory = "p_category"
        case pChannel  = "p_channel"
        case pEnabled  = "p_enabled"
    }

    public init(groupId: UUID, category: String, channel: String, enabled: Bool) {
        self.pGroupId = groupId
        self.pCategory = category
        self.pChannel = channel
        self.pEnabled = enabled
    }
}

public struct GroupVisibilityParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct SetGroupVisibilityInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pVisibility: String
    enum CodingKeys: String, CodingKey {
        case pGroupId    = "p_group_id"
        case pVisibility = "p_visibility"
    }
    public init(groupId: UUID, visibility: String) {
        self.pGroupId = groupId
        self.pVisibility = visibility
    }
}

// MARK: - Dissolution (Primitiva 25, B8)

public struct GroupDissolutionActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct ProposeDissolutionInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pReason: String

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pReason  = "p_reason"
    }

    public init(groupId: UUID, reason: String) {
        self.pGroupId = groupId
        self.pReason = reason
    }

    /// Foundation V1 only collects the reason; backend defaults
    /// `p_plan` / `p_asset_disposition` / `p_obligations_plan` to
    /// empty jsonb (the SECURITY DEFINER signature already provides
    /// defaults, so omitting the keys is safe).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pReason, forKey: .pReason)
    }
}

public struct FinalizeDissolutionInput: Encodable, Sendable, Equatable {
    public let pDissolutionId: UUID
    enum CodingKeys: String, CodingKey { case pDissolutionId = "p_dissolution_id" }
    public init(dissolutionId: UUID) { self.pDissolutionId = dissolutionId }
}

// MARK: - Roles + Permissions (Primitiva 17, B3)

public struct ListGroupRolesParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct CreateCustomRoleInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pKey: String
    public let pName: String
    public let pDescription: String?
    public let pPermissionKeys: [String]

    enum CodingKeys: String, CodingKey {
        case pGroupId        = "p_group_id"
        case pKey            = "p_key"
        case pName           = "p_name"
        case pDescription    = "p_description"
        case pPermissionKeys = "p_permission_keys"
    }

    public init(
        groupId: UUID,
        key: String,
        name: String,
        description: String?,
        permissionKeys: [String]
    ) {
        self.pGroupId = groupId
        self.pKey = key
        self.pName = name
        self.pDescription = description
        self.pPermissionKeys = permissionKeys
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pKey, forKey: .pKey)
        try c.encode(pName, forKey: .pName)
        try c.encodeOrNil(pDescription, forKey: .pDescription)
        try c.encode(pPermissionKeys, forKey: .pPermissionKeys)
    }
}

public struct UpdateRolePermissionsInput: Encodable, Sendable, Equatable {
    public let pRoleId: UUID
    public let pPermissionKeys: [String]

    enum CodingKeys: String, CodingKey {
        case pRoleId         = "p_role_id"
        case pPermissionKeys = "p_permission_keys"
    }

    public init(roleId: UUID, permissionKeys: [String]) {
        self.pRoleId = roleId
        self.pPermissionKeys = permissionKeys
    }
}

public struct AssignRoleToMemberInput: Encodable, Sendable, Equatable {
    public let pMembershipId: UUID
    public let pRoleId: UUID
    enum CodingKeys: String, CodingKey {
        case pMembershipId = "p_membership_id"
        case pRoleId       = "p_role_id"
    }
    public init(membershipId: UUID, roleId: UUID) {
        self.pMembershipId = membershipId
        self.pRoleId = roleId
    }
}

public struct RevokeRoleFromMemberInput: Encodable, Sendable, Equatable {
    public let pMembershipId: UUID
    public let pRoleId: UUID
    enum CodingKeys: String, CodingKey {
        case pMembershipId = "p_membership_id"
        case pRoleId       = "p_role_id"
    }
    public init(membershipId: UUID, roleId: UUID) {
        self.pMembershipId = membershipId
        self.pRoleId = roleId
    }
}

// MARK: - Boundary policy (Primitiva 2, B2)

public struct GroupBoundaryPolicyParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct SetGroupBoundaryPolicyInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pEntryMode: String
    public let pWhoCanInvite: String
    public let pRequiresApproval: Bool
    public let pExitMode: String
    public let pNotes: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId          = "p_group_id"
        case pEntryMode        = "p_entry_mode"
        case pWhoCanInvite     = "p_who_can_invite"
        case pRequiresApproval = "p_requires_approval"
        case pExitMode         = "p_exit_mode"
        case pNotes            = "p_notes"
    }

    public init(
        groupId: UUID,
        entryMode: String,
        whoCanInvite: String,
        requiresApproval: Bool,
        exitMode: String,
        notes: String? = nil
    ) {
        self.pGroupId = groupId
        self.pEntryMode = entryMode
        self.pWhoCanInvite = whoCanInvite
        self.pRequiresApproval = requiresApproval
        self.pExitMode = exitMode
        self.pNotes = notes
    }

    /// Same rationale as the other foundation params: emit every key
    /// explicitly with JSON null for nil so PostgREST overload
    /// resolution stays deterministic.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pEntryMode, forKey: .pEntryMode)
        try c.encode(pWhoCanInvite, forKey: .pWhoCanInvite)
        try c.encode(pRequiresApproval, forKey: .pRequiresApproval)
        try c.encode(pExitMode, forKey: .pExitMode)
        try c.encodeOrNil(pNotes, forKey: .pNotes)
    }
}

// MARK: - Rituals (Primitiva 21, B6)

public struct ListGroupResourceSeriesParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pRitualsOnly: Bool
    public let pIncludePast: Bool

    enum CodingKeys: String, CodingKey {
        case pGroupId     = "p_group_id"
        case pRitualsOnly = "p_rituals_only"
        case pIncludePast = "p_include_past"
    }

    public init(groupId: UUID, ritualsOnly: Bool = true, includePast: Bool = false) {
        self.pGroupId = groupId
        self.pRitualsOnly = ritualsOnly
        self.pIncludePast = includePast
    }
}

public struct CreateResourceSeriesInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pResourceType: String
    public let pCadence: String
    public let pStartsOn: Date?
    public let pEndsOn: Date?
    public let pRitualMeaning: String?
    public let pRitualMarkerKind: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId          = "p_group_id"
        case pResourceType     = "p_resource_type"
        case pCadence          = "p_cadence"
        case pStartsOn         = "p_starts_on"
        case pEndsOn           = "p_ends_on"
        case pRitualMeaning    = "p_ritual_meaning"
        case pRitualMarkerKind = "p_ritual_marker_kind"
    }

    public init(
        groupId: UUID,
        resourceType: String = "event",
        cadence: String,
        startsOn: Date? = nil,
        endsOn: Date? = nil,
        ritualMeaning: String? = nil,
        ritualMarkerKind: String? = nil
    ) {
        self.pGroupId = groupId
        self.pResourceType = resourceType
        self.pCadence = cadence
        self.pStartsOn = startsOn
        self.pEndsOn = endsOn
        self.pRitualMeaning = ritualMeaning
        self.pRitualMarkerKind = ritualMarkerKind
    }

    /// Emit every key explicitly with JSON null for nil optionals so
    /// PostgREST overload resolution remains deterministic and the
    /// pattern/template_payload defaults are left to the backend.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pResourceType, forKey: .pResourceType)
        try c.encode(pCadence, forKey: .pCadence)
        try c.encodeOrNil(pStartsOn, forKey: .pStartsOn)
        try c.encodeOrNil(pEndsOn, forKey: .pEndsOn)
        try c.encodeOrNil(pRitualMeaning, forKey: .pRitualMeaning)
        try c.encodeOrNil(pRitualMarkerKind, forKey: .pRitualMarkerKind)
    }
}

public struct UpdateResourceSeriesInput: Encodable, Sendable, Equatable {
    public let pSeriesId: UUID
    public let pRitualMeaning: String?
    public let pRitualMarkerKind: String?
    public let pEndsOn: Date?

    enum CodingKeys: String, CodingKey {
        case pSeriesId         = "p_series_id"
        case pRitualMeaning    = "p_ritual_meaning"
        case pRitualMarkerKind = "p_ritual_marker_kind"
        case pEndsOn           = "p_ends_on"
    }

    public init(
        seriesId: UUID,
        ritualMeaning: String? = nil,
        ritualMarkerKind: String? = nil,
        endsOn: Date? = nil
    ) {
        self.pSeriesId = seriesId
        self.pRitualMeaning = ritualMeaning
        self.pRitualMarkerKind = ritualMarkerKind
        self.pEndsOn = endsOn
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pSeriesId, forKey: .pSeriesId)
        try c.encodeOrNil(pRitualMeaning, forKey: .pRitualMeaning)
        try c.encodeOrNil(pRitualMarkerKind, forKey: .pRitualMarkerKind)
        try c.encodeOrNil(pEndsOn, forKey: .pEndsOn)
    }
}

// MARK: - Disputes UI completion (Primitiva 14, C2)

public struct DisputeDetailParams: Encodable, Sendable {
    public let pDisputeId: UUID
    enum CodingKeys: String, CodingKey { case pDisputeId = "p_dispute_id" }
    public init(disputeId: UUID) { self.pDisputeId = disputeId }
}

public struct ListDisputeEventsParams: Encodable, Sendable {
    public let pDisputeId: UUID
    public let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pDisputeId = "p_dispute_id"
        case pLimit     = "p_limit"
    }

    public init(disputeId: UUID, limit: Int = 200) {
        self.pDisputeId = disputeId
        self.pLimit = limit
    }
}

public struct OpenDisputeInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pSubjectKind: String
    public let pSubjectId: UUID?
    public let pTitle: String
    public let pDescription: String?
    public let pRespondentMembershipId: UUID?

    enum CodingKeys: String, CodingKey {
        case pGroupId                = "p_group_id"
        case pSubjectKind            = "p_subject_kind"
        case pSubjectId              = "p_subject_id"
        case pTitle                  = "p_title"
        case pDescription            = "p_description"
        case pRespondentMembershipId = "p_respondent_membership_id"
    }

    public init(
        groupId: UUID,
        subjectKind: String,
        subjectId: UUID? = nil,
        title: String,
        description: String? = nil,
        respondentMembershipId: UUID? = nil
    ) {
        self.pGroupId = groupId
        self.pSubjectKind = subjectKind
        self.pSubjectId = subjectId
        self.pTitle = title
        self.pDescription = description
        self.pRespondentMembershipId = respondentMembershipId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pSubjectKind, forKey: .pSubjectKind)
        try c.encodeOrNil(pSubjectId, forKey: .pSubjectId)
        try c.encode(pTitle, forKey: .pTitle)
        try c.encodeOrNil(pDescription, forKey: .pDescription)
        try c.encodeOrNil(pRespondentMembershipId, forKey: .pRespondentMembershipId)
    }
}

public struct AppendDisputeEventInput: Encodable, Sendable, Equatable {
    public let pDisputeId: UUID
    public let pEventType: String
    public let pBody: String?
    /// JSON-encoded as `{}` when omitted; the backend defaults the
    /// column itself but PostgREST overload resolution requires the
    /// key to be present.
    public let pMetadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case pDisputeId = "p_dispute_id"
        case pEventType = "p_event_type"
        case pBody      = "p_body"
        case pMetadata  = "p_metadata"
    }

    public init(
        disputeId: UUID,
        eventType: String,
        body: String?,
        metadata: [String: String] = [:]
    ) {
        self.pDisputeId = disputeId
        self.pEventType = eventType
        self.pBody = body
        self.pMetadata = metadata
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pDisputeId, forKey: .pDisputeId)
        try c.encode(pEventType, forKey: .pEventType)
        try c.encodeOrNil(pBody, forKey: .pBody)
        try c.encode(pMetadata, forKey: .pMetadata)
    }
}

public struct RecordDisputeResolutionInput: Encodable, Sendable, Equatable {
    public let pDisputeId: UUID
    public let pMethod: String
    public let pResolutionText: String
    public let pOutcome: [String: String]?

    enum CodingKeys: String, CodingKey {
        case pDisputeId      = "p_dispute_id"
        case pMethod         = "p_method"
        case pResolutionText = "p_resolution_text"
        case pOutcome        = "p_outcome"
    }

    public init(
        disputeId: UUID,
        method: String,
        resolutionText: String,
        outcome: [String: String]? = nil
    ) {
        self.pDisputeId = disputeId
        self.pMethod = method
        self.pResolutionText = resolutionText
        self.pOutcome = outcome
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pDisputeId, forKey: .pDisputeId)
        try c.encode(pMethod, forKey: .pMethod)
        try c.encode(pResolutionText, forKey: .pResolutionText)
        try c.encodeOrNil(pOutcome, forKey: .pOutcome)
    }
}

public struct EscalateDisputeToVoteInput: Encodable, Sendable, Equatable {
    public let pDisputeId: UUID
    public let pDecisionTitle: String
    public let pDecisionMethod: String
    public let pClosesAt: Date?

    enum CodingKeys: String, CodingKey {
        case pDisputeId      = "p_dispute_id"
        case pDecisionTitle  = "p_decision_title"
        case pDecisionMethod = "p_decision_method"
        case pClosesAt       = "p_closes_at"
    }

    public init(
        disputeId: UUID,
        decisionTitle: String,
        decisionMethod: String = "majority",
        closesAt: Date? = nil
    ) {
        self.pDisputeId = disputeId
        self.pDecisionTitle = decisionTitle
        self.pDecisionMethod = decisionMethod
        self.pClosesAt = closesAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pDisputeId, forKey: .pDisputeId)
        try c.encode(pDecisionTitle, forKey: .pDecisionTitle)
        try c.encode(pDecisionMethod, forKey: .pDecisionMethod)
        try c.encodeOrNil(pClosesAt, forKey: .pClosesAt)
    }
}

// MARK: - Sanctions (Primitiva 11)

public struct GroupSanctionsActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pLimit   = "p_limit"
    }

    public init(groupId: UUID, limit: Int = 50) {
        self.pGroupId = groupId
        self.pLimit = limit
    }
}

public struct IssueSanctionInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pTargetMembershipId: UUID
    public let pSanctionKind: String
    public let pReason: String
    public let pAmount: Decimal?
    public let pUnit: String?
    public let pEndsAt: Date?
    public let pRuleVersionId: UUID?
    public let pSourceEventId: UUID?
    public let pClientId: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId            = "p_group_id"
        case pTargetMembershipId = "p_target_membership_id"
        case pSanctionKind       = "p_sanction_kind"
        case pReason             = "p_reason"
        case pAmount             = "p_amount"
        case pUnit               = "p_unit"
        case pEndsAt             = "p_ends_at"
        case pRuleVersionId      = "p_rule_version_id"
        case pSourceEventId      = "p_source_event_id"
        case pClientId           = "p_client_id"
    }

    public init(
        pGroupId: UUID,
        pTargetMembershipId: UUID,
        pSanctionKind: String,
        pReason: String,
        pAmount: Decimal? = nil,
        pUnit: String? = nil,
        pEndsAt: Date? = nil,
        pRuleVersionId: UUID? = nil,
        pSourceEventId: UUID? = nil,
        pClientId: String? = nil
    ) {
        self.pGroupId = pGroupId
        self.pTargetMembershipId = pTargetMembershipId
        self.pSanctionKind = pSanctionKind
        self.pReason = pReason
        self.pAmount = pAmount
        self.pUnit = pUnit
        self.pEndsAt = pEndsAt
        self.pRuleVersionId = pRuleVersionId
        self.pSourceEventId = pSourceEventId
        self.pClientId = pClientId
    }

    /// Same rationale as `RecordExpenseParams.encode(to:)` — emit
    /// optional keys as explicit JSON `null` so PostgREST overload
    /// resolution doesn't drop into the wrong signature when the
    /// caller wants the SECURITY DEFINER backend defaults.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pTargetMembershipId, forKey: .pTargetMembershipId)
        try c.encode(pSanctionKind, forKey: .pSanctionKind)
        try c.encode(pReason, forKey: .pReason)
        try c.encodeOrNil(pAmount, forKey: .pAmount)
        try c.encodeOrNil(pUnit, forKey: .pUnit)
        try c.encodeOrNil(pEndsAt, forKey: .pEndsAt)
        try c.encodeOrNil(pRuleVersionId, forKey: .pRuleVersionId)
        try c.encodeOrNil(pSourceEventId, forKey: .pSourceEventId)
        try c.encodeOrNil(pClientId, forKey: .pClientId)
    }
}

// MARK: - Reputation (Primitiva 12)

public struct MemberReputationEventsParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pSubjectMembershipId: UUID
    public let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId             = "p_group_id"
        case pSubjectMembershipId = "p_subject_membership_id"
        case pLimit               = "p_limit"
    }

    public init(groupId: UUID, subjectMembershipId: UUID, limit: Int = 50) {
        self.pGroupId = groupId
        self.pSubjectMembershipId = subjectMembershipId
        self.pLimit = limit
    }
}

// MARK: - Decision rules

public struct GroupDecisionRulesParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct SetDecisionRulesInput: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pDefaultStyle: String
    public let pQuorumMin: Int?
    public let pNotes: String?
    /// V2-G2 sub-slice 8 — canonical method (`DecisionMethod`, 8 values).
    public let pDefaultMethod: String?
    /// V2-G2 sub-slice 8 — canonical legitimacy (`LegitimacySource`, 10 values).
    public let pDefaultLegitimacySource: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId                 = "p_group_id"
        case pDefaultStyle            = "p_default_style"
        case pQuorumMin               = "p_quorum_min"
        case pNotes                   = "p_notes"
        case pDefaultMethod           = "p_default_method"
        case pDefaultLegitimacySource = "p_default_legitimacy_source"
    }

    public init(
        pGroupId: UUID,
        pDefaultStyle: String,
        pQuorumMin: Int? = nil,
        pNotes: String? = nil,
        pDefaultMethod: String? = nil,
        pDefaultLegitimacySource: String? = nil
    ) {
        self.pGroupId = pGroupId
        self.pDefaultStyle = pDefaultStyle
        self.pQuorumMin = pQuorumMin
        self.pNotes = pNotes
        self.pDefaultMethod = pDefaultMethod
        self.pDefaultLegitimacySource = pDefaultLegitimacySource
    }

    /// Same rationale as `RecordExpenseParams.encode(to:)` — emit
    /// optional keys as explicit JSON `null` so PostgREST resolves
    /// the overload deterministically.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pDefaultStyle, forKey: .pDefaultStyle)
        try c.encodeOrNil(pQuorumMin, forKey: .pQuorumMin)
        try c.encodeOrNil(pNotes, forKey: .pNotes)
        try c.encodeOrNil(pDefaultMethod, forKey: .pDefaultMethod)
        try c.encodeOrNil(pDefaultLegitimacySource, forKey: .pDefaultLegitimacySource)
    }
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

// MARK: - Decisions / Voting (Primitiva 16, C1)

public struct ListDecisionsActiveParams: Encodable, Sendable {
    public let pGroupId: UUID
    enum CodingKeys: String, CodingKey { case pGroupId = "p_group_id" }
    public init(groupId: UUID) { self.pGroupId = groupId }
}

public struct ListDecisionsHistoryParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
        case pLimit   = "p_limit"
    }

    public init(groupId: UUID, limit: Int = 50) {
        self.pGroupId = groupId
        self.pLimit = limit
    }
}

public struct DecisionDetailParams: Encodable, Sendable {
    public let pDecisionId: UUID
    enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
    public init(decisionId: UUID) { self.pDecisionId = decisionId }
}

/// Wraps the canonical `start_vote(...)` signature. Foundation only
/// exposes the small set of fields the propose sheet collects;
/// scheduling + reference linking are left as backend defaults.
public struct StartVoteParams: Encodable, Sendable, Equatable {
    public let pGroupId: UUID
    public let pTitle: String
    public let pBody: String?
    public let pDecisionType: String
    public let pMethod: String
    public let pLegitimacySource: String
    public let pOpensAt: Date?
    public let pClosesAt: Date?
    public let pThresholdPct: Decimal?
    public let pQuorumPct: Decimal?
    public let pCommitteeOnly: Bool
    public let pReferenceKind: String?
    public let pReferenceId: UUID?
    public let pOptions: [OptionDraft]?
    /// V2-G2 sub-slice 4 — jsonb-shaped metadata persisted to
    /// `group_decisions.metadata`. Used today by finalize_vote's
    /// membership handler (`target_state` key); future handlers
    /// (rule_change, budget, weight_strategy) read their own keys here.
    /// V2-G9 — switched to `RPCJSONValue` so callers can pass nested
    /// objects (e.g. `weight_strategy: {kind, config}`).
    public let pMetadata: [String: RPCJSONValue]?

    public struct OptionDraft: Encodable, Sendable, Equatable {
        public let label: String
        public let body: String?
        public init(label: String, body: String? = nil) {
            self.label = label
            self.body = body
        }
    }

    enum CodingKeys: String, CodingKey {
        case pGroupId          = "p_group_id"
        case pTitle            = "p_title"
        case pBody             = "p_body"
        case pDecisionType     = "p_decision_type"
        case pMethod           = "p_method"
        case pLegitimacySource = "p_legitimacy_source"
        case pOpensAt          = "p_opens_at"
        case pClosesAt         = "p_closes_at"
        case pThresholdPct     = "p_threshold_pct"
        case pQuorumPct        = "p_quorum_pct"
        case pCommitteeOnly    = "p_committee_only"
        case pReferenceKind    = "p_reference_kind"
        case pReferenceId      = "p_reference_id"
        case pOptions          = "p_options"
        case pMetadata         = "p_metadata"
    }

    public init(
        groupId: UUID,
        title: String,
        body: String? = nil,
        decisionType: String = "proposal",
        method: String = "majority",
        legitimacySource: String = "majority",
        opensAt: Date? = nil,
        closesAt: Date? = nil,
        thresholdPct: Decimal? = nil,
        quorumPct: Decimal? = nil,
        committeeOnly: Bool = false,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        options: [OptionDraft]? = nil,
        metadata: [String: RPCJSONValue]? = nil
    ) {
        self.pGroupId = groupId
        self.pTitle = title
        self.pBody = body
        self.pDecisionType = decisionType
        self.pMethod = method
        self.pLegitimacySource = legitimacySource
        self.pOpensAt = opensAt
        self.pClosesAt = closesAt
        self.pThresholdPct = thresholdPct
        self.pQuorumPct = quorumPct
        self.pCommitteeOnly = committeeOnly
        self.pReferenceKind = referenceKind
        self.pReferenceId = referenceId
        self.pOptions = options
        self.pMetadata = metadata
    }

    /// Emit every key explicitly; nil optionals become JSON null so
    /// PostgREST overload resolution stays deterministic for the
    /// 15-arg signature.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pGroupId, forKey: .pGroupId)
        try c.encode(pTitle, forKey: .pTitle)
        try c.encodeOrNil(pBody, forKey: .pBody)
        try c.encode(pDecisionType, forKey: .pDecisionType)
        try c.encode(pMethod, forKey: .pMethod)
        try c.encode(pLegitimacySource, forKey: .pLegitimacySource)
        try c.encodeOrNil(pOpensAt, forKey: .pOpensAt)
        try c.encodeOrNil(pClosesAt, forKey: .pClosesAt)
        try c.encodeOrNil(pThresholdPct, forKey: .pThresholdPct)
        try c.encodeOrNil(pQuorumPct, forKey: .pQuorumPct)
        try c.encode(pCommitteeOnly, forKey: .pCommitteeOnly)
        try c.encodeOrNil(pReferenceKind, forKey: .pReferenceKind)
        try c.encodeOrNil(pReferenceId, forKey: .pReferenceId)
        try c.encodeOrNil(pOptions, forKey: .pOptions)
        try c.encodeOrNil(pMetadata, forKey: .pMetadata)
    }
}

public struct CastVoteParams: Encodable, Sendable, Equatable {
    public let pDecisionId: UUID
    public let pOptionId: UUID?
    public let pVoteValue: String?
    public let pReason: String?
    /// V2-G9 — honored only when the decision's `method='weighted'`.
    /// `cast_vote` validates `0 < p_weight <= metadata.weight_strategy.config.max_weight`.
    public let pWeight: Decimal?

    enum CodingKeys: String, CodingKey {
        case pDecisionId = "p_decision_id"
        case pOptionId   = "p_option_id"
        case pVoteValue  = "p_vote_value"
        case pReason     = "p_reason"
        case pWeight     = "p_weight"
    }

    public init(
        decisionId: UUID,
        optionId: UUID? = nil,
        voteValue: String? = nil,
        reason: String? = nil,
        weight: Decimal? = nil
    ) {
        self.pDecisionId = decisionId
        self.pOptionId = optionId
        self.pVoteValue = voteValue
        self.pReason = reason
        self.pWeight = weight
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pDecisionId, forKey: .pDecisionId)
        try c.encodeOrNil(pOptionId, forKey: .pOptionId)
        try c.encodeOrNil(pVoteValue, forKey: .pVoteValue)
        try c.encodeOrNil(pReason, forKey: .pReason)
        try c.encodeOrNil(pWeight, forKey: .pWeight)
    }
}

/// V2-G9 — `cast_ranked_vote(p_decision_id, p_rankings, p_reason)`.
/// `p_rankings` is a JSON array `[{option_id, rank}, …]` where `rank` is
/// 1-based (1 = first choice). The backend rejects duplicates, ranks out
/// of range, and any `option_id` that doesn't belong to the decision.
public struct CastRankedVoteParams: Encodable, Sendable, Equatable {
    public let pDecisionId: UUID
    public let pRankings: [Ranking]
    public let pReason: String?

    public struct Ranking: Encodable, Sendable, Equatable {
        public let optionId: UUID
        public let rank: Int

        enum CodingKeys: String, CodingKey {
            case optionId = "option_id"
            case rank
        }

        public init(optionId: UUID, rank: Int) {
            self.optionId = optionId
            self.rank = rank
        }
    }

    enum CodingKeys: String, CodingKey {
        case pDecisionId = "p_decision_id"
        case pRankings   = "p_rankings"
        case pReason     = "p_reason"
    }

    public init(decisionId: UUID, rankings: [Ranking], reason: String? = nil) {
        self.pDecisionId = decisionId
        self.pRankings = rankings
        self.pReason = reason
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pDecisionId, forKey: .pDecisionId)
        try c.encode(pRankings, forKey: .pRankings)
        try c.encodeOrNil(pReason, forKey: .pReason)
    }
}

public struct FinalizeVoteParams: Encodable, Sendable {
    public let pDecisionId: UUID
    enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
    public init(decisionId: UUID) { self.pDecisionId = decisionId }
}

public struct CancelVoteParams: Encodable, Sendable, Equatable {
    public let pDecisionId: UUID
    public let pReason: String?
    enum CodingKeys: String, CodingKey {
        case pDecisionId = "p_decision_id"
        case pReason     = "p_reason"
    }
    public init(decisionId: UUID, reason: String? = nil) {
        self.pDecisionId = decisionId
        self.pReason = reason
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pDecisionId, forKey: .pDecisionId)
        try c.encodeOrNil(pReason, forKey: .pReason)
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
