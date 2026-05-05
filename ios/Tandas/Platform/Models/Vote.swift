import Foundation

/// Generic vote envelope. Supports any `VoteType`. V1 ships only
/// `fineAppeal`; V2+ uses `ruleChange`, `memberRemoval`, etc. without
/// schema changes.
///
/// Persisted in `public.votes`. Created via the `start_vote` RPC, ballots
/// recorded via `cast_vote`, resolved via `finalize_vote` (cron or
/// on-demand). Each lifecycle event emits a `SystemEvent`
/// (`voteOpened`, `voteCast`, `voteResolved`).
public struct Vote: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let voteType: VoteType
    public let referenceId: UUID
    public let title: String
    public let description: String?
    public let createdByMemberId: UUID?
    public let openedAt: Date
    public let closesAt: Date
    public var resolvedAt: Date?
    public let quorumPercent: Int
    public let thresholdPercent: Int
    public let isAnonymous: Bool
    public var status: VoteStatus
    public var counts: VoteCounts?
    public let payload: JSONConfig

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, counts, payload
        case groupId           = "group_id"
        case voteType          = "vote_type"
        case referenceId       = "reference_id"
        case createdByMemberId = "created_by_member_id"
        case openedAt          = "opened_at"
        case closesAt          = "closes_at"
        case resolvedAt        = "resolved_at"
        case quorumPercent     = "quorum_percent"
        case thresholdPercent  = "threshold_percent"
        case isAnonymous       = "is_anonymous"
    }
}

/// Discriminator for the kind of decision a `Vote` is making.
/// V1 only emits `fineAppeal`; the others are reserved for V2+.
public enum VoteType: String, Codable, Sendable, Hashable, CaseIterable {
    case fineAppeal       = "fine_appeal"
    case ruleChange       = "rule_change"
    case memberRemoval    = "member_removal"
    case fundWithdrawal   = "fund_withdrawal"
    case roleAssignment   = "role_assignment"
    case generalProposal  = "general_proposal"
    case slotDispute      = "slot_dispute"
}

/// Lifecycle state of a `Vote`. Mirrors the `votes.status` text column.
public enum VoteStatus: String, Codable, Sendable, Hashable {
    case open
    case closed
    case resolved
    case quorumFailed = "quorum_failed"
    case cancelled
}

/// Aggregate of vote_casts for a vote. Stored in `votes.counts` jsonb after
/// `finalize_vote` runs. Consumers can also read live counts via
/// `vote_counts_view`.
public struct VoteCounts: Codable, Sendable, Equatable, Hashable {
    public let inFavor: Int
    public let against: Int
    public let abstained: Int
    public let pending: Int
    public let totalEligible: Int
    public let resolution: VoteResolution?

    enum CodingKeys: String, CodingKey {
        case inFavor, against, abstained, pending, resolution
        case totalEligible = "totalEligible"
    }
}

/// Outcome of a closed vote. Stored on `votes.counts.resolution` and
/// also mirrored in `votes.payload.resolution` for legacy consumers.
public enum VoteResolution: String, Codable, Sendable, Hashable {
    case passed
    case failed
    case quorumFailed = "quorum_failed"
}
