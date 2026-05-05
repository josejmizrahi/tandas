import Foundation

/// One ballot cast by one member on one vote. Persisted in
/// `public.vote_casts`, unique on `(vote_id, member_id)`. Anonymity is
/// enforced by RLS — only the casting member can SELECT their own row;
/// aggregate counts come from `vote_counts_view` which bypasses RLS.
public struct VoteCast: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let voteId: UUID
    public let memberId: UUID
    public var choice: VoteChoice
    public var castAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, choice
        case voteId    = "vote_id"
        case memberId  = "member_id"
        case castAt    = "cast_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Possible values for a `VoteCast.choice`. `pending` is the seed value
/// inserted when `start_vote` opens the vote; the member updates to one of
/// the others via `cast_vote`.
public enum VoteChoice: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case inFavor   = "in_favor"
    case against
    case abstained
}
