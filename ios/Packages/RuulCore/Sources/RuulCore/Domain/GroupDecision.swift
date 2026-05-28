import Foundation

/// Primitiva 16 (Decisions / Voting). Mirrors `public.group_decisions`
/// + `public.group_decision_options` + `public.group_votes` via the
/// `list_decisions_active(...)`, `list_decisions_history(...)` and
/// `decision_detail(...)` RPCs.
///
/// `group_votes` is append-only — "current vote" is the row with the
/// largest `seq` per voter. The list RPCs already collapse that into a
/// flat tally row; the detail RPC exposes the same shape plus the
/// caller's own current vote.
public enum DecisionStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case draft
    case open
    case passed
    case rejected
    case cancelled

    public var label: LocalizedStringResource {
        switch self {
        case .draft:     return L10n.Decisions.statusDraft
        case .open:      return L10n.Decisions.statusOpen
        case .passed:    return L10n.Decisions.statusPassed
        case .rejected:  return L10n.Decisions.statusRejected
        case .cancelled: return L10n.Decisions.statusCancelled
        }
    }

    public var isOpen: Bool { self == .open }
}

/// Voting methods as written by `start_vote`. Mirrors the small set
/// `finalize_vote` understands; new backend values fall back to
/// `.other` so a forward-compatible backend never crashes the client.
public enum DecisionMethod: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case majority
    case supermajority
    case unanimity
    case consensus
    case consent
    case other

    public var id: String { rawValue }

    /// Methods we expose in the propose sheet. `other` is decode-only —
    /// it represents unknown backend values so we don't crash, but the
    /// picker never offers it.
    public static let selectable: [DecisionMethod] = [
        .majority, .supermajority, .unanimity, .consensus, .consent
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .majority:      return L10n.Decisions.methodMajority
        case .supermajority: return L10n.Decisions.methodSupermajority
        case .unanimity:     return L10n.Decisions.methodUnanimity
        case .consensus:     return L10n.Decisions.methodConsensus
        case .consent:       return L10n.Decisions.methodConsent
        case .other:         return L10n.Decisions.methodOther
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .majority:      return L10n.Decisions.methodMajoritySubtitle
        case .supermajority: return L10n.Decisions.methodSupermajoritySubtitle
        case .unanimity:     return L10n.Decisions.methodUnanimitySubtitle
        case .consensus:     return L10n.Decisions.methodConsensusSubtitle
        case .consent:       return L10n.Decisions.methodConsentSubtitle
        case .other:         return L10n.Decisions.methodOtherSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .majority:      return "chart.bar.fill"
        case .supermajority: return "chart.bar.doc.horizontal"
        case .unanimity:     return "hand.thumbsup"
        case .consensus:     return "person.3.sequence"
        case .consent:       return "hand.raised"
        case .other:         return "questionmark.circle"
        }
    }
}

/// Decision categories. Mirrors `group_decisions.decision_type`.
public enum DecisionType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case proposal
    case rule
    case sanction
    case mandate
    case dissolution
    case other

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .proposal:    return L10n.Decisions.typeProposal
        case .rule:        return L10n.Decisions.typeRule
        case .sanction:    return L10n.Decisions.typeSanction
        case .mandate:     return L10n.Decisions.typeMandate
        case .dissolution: return L10n.Decisions.typeDissolution
        case .other:       return L10n.Decisions.typeOther
        }
    }
}

/// One of the four ballot values a member can cast. Mirrors
/// `group_votes.vote_value`.
public enum VoteValue: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case yes
    case no
    case abstain
    case block

    public var id: String { rawValue }

    public static let displayOrder: [VoteValue] = [.yes, .no, .abstain, .block]

    public var label: LocalizedStringResource {
        switch self {
        case .yes:     return L10n.Decisions.voteYes
        case .no:      return L10n.Decisions.voteNo
        case .abstain: return L10n.Decisions.voteAbstain
        case .block:   return L10n.Decisions.voteBlock
        }
    }

    public var systemImageName: String {
        switch self {
        case .yes:     return "checkmark.circle"
        case .no:      return "xmark.circle"
        case .abstain: return "minus.circle"
        case .block:   return "hand.raised.fill"
        }
    }
}

/// A single option row inside a decision. Mirrors
/// `public.group_decision_options`.
public struct GroupDecisionOption: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let label: String
    public let body: String?
    public let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case body
        case sortOrder = "sort_order"
    }

    public init(id: UUID, label: String, body: String? = nil, sortOrder: Int = 0) {
        self.id = id
        self.label = label
        self.body = body
        self.sortOrder = sortOrder
    }
}

/// Caller's own current vote on a decision. Only populated when the
/// caller has cast at least one vote; the row reflects the latest
/// `seq` (append-only semantics).
public struct GroupDecisionMyVote: Codable, Equatable, Sendable, Hashable {
    public let voteValue: VoteValue?
    public let optionId: UUID?
    public let reason: String?
    public let castAt: Date?

    enum CodingKeys: String, CodingKey {
        case voteValue = "vote_value"
        case optionId  = "option_id"
        case reason
        case castAt    = "cast_at"
    }

    public init(voteValue: VoteValue? = nil, optionId: UUID? = nil, reason: String? = nil, castAt: Date? = nil) {
        self.voteValue = voteValue
        self.optionId = optionId
        self.reason = reason
        self.castAt = castAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .voteValue)
        self.voteValue = raw.flatMap { VoteValue(rawValue: $0) }
        self.optionId = try c.decodeIfPresent(UUID.self, forKey: .optionId)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.castAt = try c.decodeIfPresent(Date.self, forKey: .castAt)
    }
}

/// Aggregated tally of current votes on a decision.
public struct GroupDecisionTally: Codable, Equatable, Sendable, Hashable {
    public let voteCount: Int
    public let yesCount: Decimal
    public let noCount: Decimal
    public let abstainCount: Decimal
    public let blockCount: Decimal

    enum CodingKeys: String, CodingKey {
        case voteCount    = "vote_count"
        case yesCount     = "yes_count"
        case noCount      = "no_count"
        case abstainCount = "abstain_count"
        case blockCount   = "block_count"
    }

    public init(
        voteCount: Int = 0,
        yesCount: Decimal = 0,
        noCount: Decimal = 0,
        abstainCount: Decimal = 0,
        blockCount: Decimal = 0
    ) {
        self.voteCount = voteCount
        self.yesCount = yesCount
        self.noCount = noCount
        self.abstainCount = abstainCount
        self.blockCount = blockCount
    }
}

/// Typed view over `group_decisions.result` jsonb. Populated when
/// `finalize_vote` (or `cancel_vote`) runs; empty `{}` while the
/// decision is still open.
public struct DecisionResult: Codable, Equatable, Sendable, Hashable {
    public let outcome: String?
    public let yes: Decimal?
    public let no: Decimal?
    public let abstain: Decimal?
    public let block: Decimal?
    public let cancelReason: String?

    enum CodingKeys: String, CodingKey {
        case outcome
        case yes
        case no
        case abstain
        case block
        case cancelReason = "cancel_reason"
    }

    public init(
        outcome: String? = nil,
        yes: Decimal? = nil,
        no: Decimal? = nil,
        abstain: Decimal? = nil,
        block: Decimal? = nil,
        cancelReason: String? = nil
    ) {
        self.outcome = outcome
        self.yes = yes
        self.no = no
        self.abstain = abstain
        self.block = block
        self.cancelReason = cancelReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        self.yes = try c.decodeIfPresent(Decimal.self, forKey: .yes)
        self.no = try c.decodeIfPresent(Decimal.self, forKey: .no)
        self.abstain = try c.decodeIfPresent(Decimal.self, forKey: .abstain)
        self.block = try c.decodeIfPresent(Decimal.self, forKey: .block)
        self.cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
    }
}

/// Flat list-row shape returned by `list_decisions_active` /
/// `list_decisions_history`. Tally + caller's current vote are
/// already pre-joined so the list UI can render without a second hop.
public struct GroupDecisionSummary: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let title: String
    public let body: String?
    public let decisionType: DecisionType
    public let method: DecisionMethod
    public let legitimacySource: String?
    public let status: DecisionStatus
    public let thresholdPct: Decimal?
    public let quorumPct: Decimal?
    public let referenceKind: String?
    public let referenceId: UUID?
    public let opensAt: Date?
    public let closesAt: Date?
    public let decidedAt: Date?
    public let createdAt: Date?
    public let createdBy: UUID?
    public let createdByDisplayName: String?
    public let optionCount: Int
    public let tally: GroupDecisionTally
    public let result: DecisionResult?
    public let myVoteValue: VoteValue?
    public let myVoteOptionId: UUID?

    enum CodingKeys: String, CodingKey {
        case id                   = "decision_id"
        case groupId              = "group_id"
        case title
        case body
        case decisionType         = "decision_type"
        case method
        case legitimacySource     = "legitimacy_source"
        case status
        case thresholdPct         = "threshold_pct"
        case quorumPct            = "quorum_pct"
        case referenceKind        = "reference_kind"
        case referenceId          = "reference_id"
        case opensAt              = "opens_at"
        case closesAt             = "closes_at"
        case decidedAt            = "decided_at"
        case createdAt            = "created_at"
        case createdBy            = "created_by"
        case createdByDisplayName = "created_by_display_name"
        case optionCount          = "option_count"
        case voteCount            = "vote_count"
        case yesCount             = "yes_count"
        case noCount              = "no_count"
        case abstainCount         = "abstain_count"
        case blockCount           = "block_count"
        case result
        case myVoteValue          = "my_vote_value"
        case myVoteOptionId       = "my_vote_option_id"
    }

    public init(
        id: UUID,
        groupId: UUID,
        title: String,
        body: String? = nil,
        decisionType: DecisionType = .proposal,
        method: DecisionMethod = .majority,
        legitimacySource: String? = nil,
        status: DecisionStatus = .open,
        thresholdPct: Decimal? = nil,
        quorumPct: Decimal? = nil,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        opensAt: Date? = nil,
        closesAt: Date? = nil,
        decidedAt: Date? = nil,
        createdAt: Date? = nil,
        createdBy: UUID? = nil,
        createdByDisplayName: String? = nil,
        optionCount: Int = 0,
        tally: GroupDecisionTally = GroupDecisionTally(),
        result: DecisionResult? = nil,
        myVoteValue: VoteValue? = nil,
        myVoteOptionId: UUID? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.title = title
        self.body = body
        self.decisionType = decisionType
        self.method = method
        self.legitimacySource = legitimacySource
        self.status = status
        self.thresholdPct = thresholdPct
        self.quorumPct = quorumPct
        self.referenceKind = referenceKind
        self.referenceId = referenceId
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.decidedAt = decidedAt
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.createdByDisplayName = createdByDisplayName
        self.optionCount = optionCount
        self.tally = tally
        self.result = result
        self.myVoteValue = myVoteValue
        self.myVoteOptionId = myVoteOptionId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        let rawType = try c.decodeIfPresent(String.self, forKey: .decisionType) ?? "proposal"
        self.decisionType = DecisionType(rawValue: rawType) ?? .other
        let rawMethod = try c.decodeIfPresent(String.self, forKey: .method) ?? "majority"
        self.method = DecisionMethod(rawValue: rawMethod) ?? .other
        self.legitimacySource = try c.decodeIfPresent(String.self, forKey: .legitimacySource)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.status = DecisionStatus(rawValue: rawStatus) ?? .open
        self.thresholdPct = try c.decodeIfPresent(Decimal.self, forKey: .thresholdPct)
        self.quorumPct = try c.decodeIfPresent(Decimal.self, forKey: .quorumPct)
        self.referenceKind = try c.decodeIfPresent(String.self, forKey: .referenceKind)
        self.referenceId = try c.decodeIfPresent(UUID.self, forKey: .referenceId)
        self.opensAt = try c.decodeIfPresent(Date.self, forKey: .opensAt)
        self.closesAt = try c.decodeIfPresent(Date.self, forKey: .closesAt)
        self.decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdByDisplayName = try c.decodeIfPresent(String.self, forKey: .createdByDisplayName)
        self.optionCount = try c.decodeIfPresent(Int.self, forKey: .optionCount) ?? 0
        self.tally = GroupDecisionTally(
            voteCount: try c.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0,
            yesCount: try c.decodeIfPresent(Decimal.self, forKey: .yesCount) ?? 0,
            noCount: try c.decodeIfPresent(Decimal.self, forKey: .noCount) ?? 0,
            abstainCount: try c.decodeIfPresent(Decimal.self, forKey: .abstainCount) ?? 0,
            blockCount: try c.decodeIfPresent(Decimal.self, forKey: .blockCount) ?? 0
        )
        self.result = try c.decodeIfPresent(DecisionResult.self, forKey: .result)
        let rawMy = try c.decodeIfPresent(String.self, forKey: .myVoteValue)
        self.myVoteValue = rawMy.flatMap { VoteValue(rawValue: $0) }
        self.myVoteOptionId = try c.decodeIfPresent(UUID.self, forKey: .myVoteOptionId)
    }

    /// Encoder kept symmetric with the custom decoder so the type
    /// stays `Codable`-correct for tests that round-trip via JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encode(decisionType.rawValue, forKey: .decisionType)
        try c.encode(method.rawValue, forKey: .method)
        try c.encodeIfPresent(legitimacySource, forKey: .legitimacySource)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(thresholdPct, forKey: .thresholdPct)
        try c.encodeIfPresent(quorumPct, forKey: .quorumPct)
        try c.encodeIfPresent(referenceKind, forKey: .referenceKind)
        try c.encodeIfPresent(referenceId, forKey: .referenceId)
        try c.encodeIfPresent(opensAt, forKey: .opensAt)
        try c.encodeIfPresent(closesAt, forKey: .closesAt)
        try c.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(createdByDisplayName, forKey: .createdByDisplayName)
        try c.encode(optionCount, forKey: .optionCount)
        try c.encode(tally.voteCount, forKey: .voteCount)
        try c.encode(tally.yesCount, forKey: .yesCount)
        try c.encode(tally.noCount, forKey: .noCount)
        try c.encode(tally.abstainCount, forKey: .abstainCount)
        try c.encode(tally.blockCount, forKey: .blockCount)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(myVoteValue?.rawValue, forKey: .myVoteValue)
        try c.encodeIfPresent(myVoteOptionId, forKey: .myVoteOptionId)
    }
}

/// Detail shape returned by `decision_detail(p_decision_id)`. Same
/// scalar fields as `GroupDecisionSummary` plus a nested options array
/// + per-option current tally + caller's full last vote (with reason).
public struct GroupDecisionDetail: Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let title: String
    public let body: String?
    public let decisionType: DecisionType
    public let method: DecisionMethod
    public let legitimacySource: String?
    public let status: DecisionStatus
    public let thresholdPct: Decimal?
    public let quorumPct: Decimal?
    public let referenceKind: String?
    public let referenceId: UUID?
    public let opensAt: Date?
    public let closesAt: Date?
    public let decidedAt: Date?
    public let createdAt: Date?
    public let createdBy: UUID?
    public let createdByDisplayName: String?
    public let result: DecisionResult?
    public let options: [GroupDecisionOption]
    public let tally: GroupDecisionTally
    public let optionTally: [UUID: Int]
    public let myVote: GroupDecisionMyVote?

    enum CodingKeys: String, CodingKey {
        case id                   = "decision_id"
        case groupId              = "group_id"
        case title
        case body
        case decisionType         = "decision_type"
        case method
        case legitimacySource     = "legitimacy_source"
        case status
        case thresholdPct         = "threshold_pct"
        case quorumPct            = "quorum_pct"
        case referenceKind        = "reference_kind"
        case referenceId          = "reference_id"
        case opensAt              = "opens_at"
        case closesAt             = "closes_at"
        case decidedAt            = "decided_at"
        case createdAt            = "created_at"
        case createdBy            = "created_by"
        case createdByDisplayName = "created_by_display_name"
        case result
        case options
        case tally
        case optionTally          = "option_tally"
        case myVote               = "my_vote"
    }

    public init(
        id: UUID,
        groupId: UUID,
        title: String,
        body: String? = nil,
        decisionType: DecisionType = .proposal,
        method: DecisionMethod = .majority,
        legitimacySource: String? = nil,
        status: DecisionStatus = .open,
        thresholdPct: Decimal? = nil,
        quorumPct: Decimal? = nil,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        opensAt: Date? = nil,
        closesAt: Date? = nil,
        decidedAt: Date? = nil,
        createdAt: Date? = nil,
        createdBy: UUID? = nil,
        createdByDisplayName: String? = nil,
        result: DecisionResult? = nil,
        options: [GroupDecisionOption] = [],
        tally: GroupDecisionTally = GroupDecisionTally(),
        optionTally: [UUID: Int] = [:],
        myVote: GroupDecisionMyVote? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.title = title
        self.body = body
        self.decisionType = decisionType
        self.method = method
        self.legitimacySource = legitimacySource
        self.status = status
        self.thresholdPct = thresholdPct
        self.quorumPct = quorumPct
        self.referenceKind = referenceKind
        self.referenceId = referenceId
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.decidedAt = decidedAt
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.createdByDisplayName = createdByDisplayName
        self.result = result
        self.options = options
        self.tally = tally
        self.optionTally = optionTally
        self.myVote = myVote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        let rawType = try c.decodeIfPresent(String.self, forKey: .decisionType) ?? "proposal"
        self.decisionType = DecisionType(rawValue: rawType) ?? .other
        let rawMethod = try c.decodeIfPresent(String.self, forKey: .method) ?? "majority"
        self.method = DecisionMethod(rawValue: rawMethod) ?? .other
        self.legitimacySource = try c.decodeIfPresent(String.self, forKey: .legitimacySource)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        self.status = DecisionStatus(rawValue: rawStatus) ?? .open
        self.thresholdPct = try c.decodeIfPresent(Decimal.self, forKey: .thresholdPct)
        self.quorumPct = try c.decodeIfPresent(Decimal.self, forKey: .quorumPct)
        self.referenceKind = try c.decodeIfPresent(String.self, forKey: .referenceKind)
        self.referenceId = try c.decodeIfPresent(UUID.self, forKey: .referenceId)
        self.opensAt = try c.decodeIfPresent(Date.self, forKey: .opensAt)
        self.closesAt = try c.decodeIfPresent(Date.self, forKey: .closesAt)
        self.decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdByDisplayName = try c.decodeIfPresent(String.self, forKey: .createdByDisplayName)
        self.result = try c.decodeIfPresent(DecisionResult.self, forKey: .result)
        self.options = try c.decodeIfPresent([GroupDecisionOption].self, forKey: .options) ?? []
        self.tally = try c.decodeIfPresent(GroupDecisionTally.self, forKey: .tally) ?? GroupDecisionTally()
        if let rawMap = try c.decodeIfPresent([String: Int].self, forKey: .optionTally) {
            var parsed: [UUID: Int] = [:]
            for (k, v) in rawMap {
                if let id = UUID(uuidString: k) { parsed[id] = v }
            }
            self.optionTally = parsed
        } else {
            self.optionTally = [:]
        }
        self.myVote = try c.decodeIfPresent(GroupDecisionMyVote.self, forKey: .myVote)
    }
}

public extension GroupDecisionSummary {
    /// `true` when the caller has cast a vote we know about.
    var hasMyVote: Bool { myVoteValue != nil }
}

public extension GroupDecisionDetail {
    var hasMyVote: Bool { myVote?.voteValue != nil }
    var isOpenForVoting: Bool { status == .open }
    var totalWeight: Decimal { tally.yesCount + tally.noCount + tally.abstainCount + tally.blockCount }
}
