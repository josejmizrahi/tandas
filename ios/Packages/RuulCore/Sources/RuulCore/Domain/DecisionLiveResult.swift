import Foundation

/// V3 D.24 P12A — payload de `decision_live_result(p_decision_id)`.
/// Single round-trip que devuelve los CONTEOS FRESCOS, el voto del caller
/// (DISTINCT ON cast_at desc), el progreso de quorum/threshold y el
/// estado del execution pipeline (P5).
///
/// **Complemento, NO reemplazo de `GroupDecisionDetail`:** la vista
/// `DecisionDetailView` sigue usando el detail rico (options, body,
/// reference, provenance, actions) y consume este live result para
/// refrescar tally + quorum/threshold + execution status. Si la RPC
/// falla, todo cae al render legacy (detail.tally + computed progress).
public struct DecisionLiveResult: Codable, Equatable, Sendable, Hashable {
    public let decisionId: UUID
    public let voteCounts: VoteCounts
    public let myVote: MyVote?
    public let eligibleVotersCount: Int
    public let quorum: QuorumStatus
    public let threshold: ThresholdStatus
    public let executionStatus: String?
    public let executionAttempts: Int?
    public let executionError: String?

    enum CodingKeys: String, CodingKey {
        case decision
        case currentVoteCounts    = "current_vote_counts"
        case myVote               = "my_vote"
        case eligibleVotersCount  = "eligible_voters_count"
        case quorumStatus         = "quorum_status"
        case thresholdStatus      = "threshold_status"
        case executionStatus      = "execution_status"
        case executionAttempts    = "execution_attempts"
        case executionError       = "execution_error"
    }

    private enum DecisionRowKeys: String, CodingKey {
        case id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decisionRow = try c.nestedContainer(keyedBy: DecisionRowKeys.self, forKey: .decision)
        self.decisionId            = try decisionRow.decode(UUID.self, forKey: .id)
        self.voteCounts            = try c.decode(VoteCounts.self, forKey: .currentVoteCounts)
        self.myVote                = try c.decodeIfPresent(MyVote.self, forKey: .myVote)
        self.eligibleVotersCount   = try c.decodeIfPresent(Int.self, forKey: .eligibleVotersCount) ?? 0
        self.quorum                = try c.decode(QuorumStatus.self, forKey: .quorumStatus)
        self.threshold             = try c.decode(ThresholdStatus.self, forKey: .thresholdStatus)
        self.executionStatus       = try c.decodeIfPresent(String.self, forKey: .executionStatus)
        self.executionAttempts     = try c.decodeIfPresent(Int.self, forKey: .executionAttempts)
        self.executionError        = try c.decodeIfPresent(String.self, forKey: .executionError)
    }

    public func encode(to encoder: Encoder) throws {
        // Not used over the wire (read-only RPC) but synthesizing
        // makes the type cleanly Codable for tests/snapshots.
        var c = encoder.container(keyedBy: CodingKeys.self)
        var d = c.nestedContainer(keyedBy: DecisionRowKeys.self, forKey: .decision)
        try d.encode(decisionId, forKey: .id)
        try c.encode(voteCounts,           forKey: .currentVoteCounts)
        try c.encodeIfPresent(myVote,      forKey: .myVote)
        try c.encode(eligibleVotersCount,  forKey: .eligibleVotersCount)
        try c.encode(quorum,               forKey: .quorumStatus)
        try c.encode(threshold,            forKey: .thresholdStatus)
        try c.encodeIfPresent(executionStatus,   forKey: .executionStatus)
        try c.encodeIfPresent(executionAttempts, forKey: .executionAttempts)
        try c.encodeIfPresent(executionError,    forKey: .executionError)
    }

    public struct VoteCounts: Codable, Equatable, Sendable, Hashable {
        public let yes: Int
        public let no: Int
        public let abstain: Int
        public let maybe: Int
        public let total: Int

        public init(yes: Int = 0, no: Int = 0, abstain: Int = 0, maybe: Int = 0, total: Int = 0) {
            self.yes = yes; self.no = no; self.abstain = abstain
            self.maybe = maybe; self.total = total
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.yes     = try c.decodeIfPresent(Int.self, forKey: .yes) ?? 0
            self.no      = try c.decodeIfPresent(Int.self, forKey: .no) ?? 0
            self.abstain = try c.decodeIfPresent(Int.self, forKey: .abstain) ?? 0
            self.maybe   = try c.decodeIfPresent(Int.self, forKey: .maybe) ?? 0
            self.total   = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        }
    }

    public struct MyVote: Codable, Equatable, Sendable, Hashable {
        public let voteValue: VoteValue?
        public let castAt: Date?
        public let reason: String?

        enum CodingKeys: String, CodingKey {
            case voteValue = "vote_value"
            case castAt    = "cast_at"
            case reason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decodeIfPresent(String.self, forKey: .voteValue)
            self.voteValue = raw.flatMap { VoteValue(rawValue: $0) }
            self.castAt    = try c.decodeIfPresent(Date.self, forKey: .castAt)
            self.reason    = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    public struct QuorumStatus: Codable, Equatable, Sendable, Hashable {
        public let requiredPct: Decimal?
        public let currentPct: Decimal
        public let reached: Bool

        enum CodingKeys: String, CodingKey {
            case requiredPct = "required_pct"
            case currentPct  = "current_pct"
            case reached
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.requiredPct = try c.decodeIfPresent(Decimal.self, forKey: .requiredPct)
            self.currentPct  = try c.decodeIfPresent(Decimal.self, forKey: .currentPct) ?? 0
            self.reached     = try c.decodeIfPresent(Bool.self, forKey: .reached) ?? false
        }
    }

    public struct ThresholdStatus: Codable, Equatable, Sendable, Hashable {
        public let requiredPct: Decimal?
        public let currentYesPct: Decimal
        public let reached: Bool

        enum CodingKeys: String, CodingKey {
            case requiredPct   = "required_pct"
            case currentYesPct = "current_yes_pct"
            case reached
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.requiredPct   = try c.decodeIfPresent(Decimal.self, forKey: .requiredPct)
            self.currentYesPct = try c.decodeIfPresent(Decimal.self, forKey: .currentYesPct) ?? 0
            self.reached       = try c.decodeIfPresent(Bool.self, forKey: .reached) ?? false
        }
    }
}
