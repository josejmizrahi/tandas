import Foundation
import Supabase

/// Reads + casts ballots on a `Vote`. RLS allows each member to SELECT
/// only their own row on `vote_casts` (anonymity). Aggregate counts come
/// from `vote_counts_view` which bypasses RLS.
///
/// `cast_vote` is a SECURITY DEFINER RPC that updates the caller's existing
/// pending cast (seeded by `start_vote` for all eligible members at open
/// time). It also emits the `voteCast` system event.
protocol VoteCastRepository: Actor {
    /// The caller's own ballot for a vote, if eligible. RLS returns nil
    /// when caller is not a member of the vote's group.
    func myCast(voteId: UUID, userMemberId: UUID) async throws -> VoteCast?

    /// Aggregated anonymous counts for a vote. Reads `vote_counts_view`.
    func counts(voteId: UUID) async throws -> VoteCounts?

    /// Records the caller's vote choice via the `cast_vote` RPC. Idempotent
    /// — re-casting updates the existing row. Throws if vote is closed.
    func cast(voteId: UUID, choice: VoteChoice) async throws
}

// MARK: - Mock

actor MockVoteCastRepository: VoteCastRepository {
    private var store: [VoteCast] = []
    var nextCastError: Error?

    init(seed: [VoteCast] = []) { self.store = seed }

    func myCast(voteId: UUID, userMemberId: UUID) async throws -> VoteCast? {
        store.first { $0.voteId == voteId && $0.memberId == userMemberId }
    }

    func counts(voteId: UUID) async throws -> VoteCounts? {
        let rows = store.filter { $0.voteId == voteId }
        guard !rows.isEmpty else { return nil }
        let inFavor   = rows.filter { $0.choice == .inFavor }.count
        let against   = rows.filter { $0.choice == .against }.count
        let abstained = rows.filter { $0.choice == .abstained }.count
        let pending   = rows.filter { $0.choice == .pending }.count
        return VoteCounts(
            inFavor: inFavor,
            against: against,
            abstained: abstained,
            pending: pending,
            totalEligible: rows.count,
            resolution: nil
        )
    }

    func cast(voteId: UUID, choice: VoteChoice) async throws {
        if let err = nextCastError { nextCastError = nil; throw err }
        // Mock: assume single test member; just append/update
        if let idx = store.firstIndex(where: { $0.voteId == voteId }) {
            var c = store[idx]
            c.choice = choice
            c.castAt = .now
            c.updatedAt = .now
            store[idx] = c
        }
    }
}

// MARK: - Live

actor LiveVoteCastRepository: VoteCastRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func myCast(voteId: UUID, userMemberId: UUID) async throws -> VoteCast? {
        let rows: [VoteCast] = try await client
            .from("vote_casts")
            .select("*")
            .eq("vote_id",   value: voteId.uuidString.lowercased())
            .eq("member_id", value: userMemberId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func counts(voteId: UUID) async throws -> VoteCounts? {
        struct Row: Decodable {
            let vote_id: UUID
            let in_favor: Int
            let against: Int
            let abstained: Int
            let pending: Int
            let total_eligible: Int
        }
        let rows: [Row] = try await client
            .from("vote_counts_view")
            .select("*")
            .eq("vote_id", value: voteId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let r = rows.first else { return nil }
        return VoteCounts(
            inFavor: r.in_favor,
            against: r.against,
            abstained: r.abstained,
            pending: r.pending,
            totalEligible: r.total_eligible,
            resolution: nil
        )
    }

    func cast(voteId: UUID, choice: VoteChoice) async throws {
        struct Params: Encodable {
            let p_vote_id: String
            let p_choice: String
        }
        let params = Params(
            p_vote_id: voteId.uuidString.lowercased(),
            p_choice:  choice.rawValue
        )
        _ = try await client.rpc("cast_vote", params: params).execute()
    }
}
