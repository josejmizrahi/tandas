import Foundation

/// A member's appeal against a proposed/officialized fine. Triggers a
/// group-wide vote with anonymized aggregate counts.
public struct Appeal: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let fineId: UUID
    public let appellantMemberId: UUID
    public let reason: String
    public let status: AppealStatus
    public let votingStartedAt: Date
    public let votingEndsAt: Date
    public let resolvedAt: Date?
    public let voteCounts: AppealVoteCounts?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        fineId: UUID,
        appellantMemberId: UUID,
        reason: String,
        status: AppealStatus = .voting,
        votingStartedAt: Date = .now,
        votingEndsAt: Date,
        resolvedAt: Date? = nil,
        voteCounts: AppealVoteCounts? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fineId = fineId
        self.appellantMemberId = appellantMemberId
        self.reason = reason
        self.status = status
        self.votingStartedAt = votingStartedAt
        self.votingEndsAt = votingEndsAt
        self.resolvedAt = resolvedAt
        self.voteCounts = voteCounts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isVotingOpen: Bool {
        status == .voting && Date.now < votingEndsAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case fineId             = "fine_id"
        case appellantMemberId  = "appellant_member_id"
        case reason
        case status
        case votingStartedAt    = "voting_started_at"
        case votingEndsAt       = "voting_ends_at"
        case resolvedAt         = "resolved_at"
        case voteCounts         = "vote_counts"
        case createdAt          = "created_at"
        case updatedAt          = "updated_at"
    }
}

public enum AppealStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case voting              = "voting"
    case resolvedInFavor     = "resolved_in_favor"
    case resolvedAgainst     = "resolved_against"
    case expired             = "expired"
}

public struct AppealVoteCounts: Sendable, Hashable, Codable {
    public let inFavor: Int
    public let against: Int
    public let abstained: Int
    public let pending: Int
    public let totalEligible: Int

    enum CodingKeys: String, CodingKey {
        case inFavor       = "in_favor"
        case against
        case abstained
        case pending
        case totalEligible = "total_eligible"
    }
}

public struct AppealVote: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let appealId: UUID
    public let memberId: UUID
    public let choice: AppealVoteChoice
    public let votedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case appealId  = "appeal_id"
        case memberId  = "member_id"
        case choice
        case votedAt   = "voted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public enum AppealVoteChoice: String, Codable, Sendable, Hashable, CaseIterable {
    case pending    = "pending"
    case inFavor    = "in_favor"
    case against    = "against"
    case abstained  = "abstained"
}
