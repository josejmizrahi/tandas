import Foundation
import Supabase

/// Reads + casts ballots on a `Vote`. RLS allows each member to SELECT
/// only their own rows on `vote_casts` (anonymity). Aggregate counts come
/// from `vote_counts_view` which bypasses RLS.
///
/// `cast_vote` is a SECURITY DEFINER RPC. Post-mig 00163 (Constitution §7
/// append-only refactor) every cast inserts a new vote_casts row; the
/// latest row per (vote, member) determines the member's current ballot.
/// `start_vote` still pre-seeds one `pending` row per eligible member at
/// vote-open time. Readers compute "latest per member" to derive the
/// current state. Re-cast is supported: another insert lands.
public protocol VoteCastRepository: Actor {
    /// The caller's own ballot for a vote, if eligible. RLS returns nil
    /// when caller is not a member of the vote's group.
    func myCast(voteId: UUID, userMemberId: UUID) async throws -> VoteCast?

    /// Aggregated anonymous counts for a vote. Reads `vote_counts_view`.
    func counts(voteId: UUID) async throws -> VoteCounts?

    /// Records the caller's vote choice via the `cast_vote` RPC. Post-mig
    /// 00163 every call inserts a new vote_casts row; re-cast supported
    /// because latest-per-(vote, member) wins. Throws if vote is closed.
    func cast(voteId: UUID, choice: VoteChoice) async throws
}

// MARK: - Mock

public actor MockVoteCastRepository: VoteCastRepository {
    private var store: [VoteCast] = []
    public var nextCastError: Error?

    public init(seed: [VoteCast] = []) { self.store = seed }

    /// Test helper: lets tests inject a one-shot error that the next `cast`
    /// call will throw. Mirrors the pattern used by `MockVoteRepository`.
    public func setNextCastError(_ error: Error?) { self.nextCastError = error }

    public func myCast(voteId: UUID, userMemberId: UUID) async throws -> VoteCast? {
        store.first { $0.voteId == voteId && $0.memberId == userMemberId }
    }

    public func counts(voteId: UUID) async throws -> VoteCounts? {
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

    public func cast(voteId: UUID, choice: VoteChoice) async throws {
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

public actor LiveVoteCastRepository: VoteCastRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func myCast(voteId: UUID, userMemberId: UUID) async throws -> VoteCast? {
        // Post-mig 00163: vote_casts is append-only. Multiple rows per
        // (vote, member) are expected (pending pre-seed + each cast).
        // Order by created_at DESC so the latest row wins.
        //
        // RLS on vote_casts already restricts SELECT to the caller's own
        // rows (anonymity). We DON'T filter by `member_id` client-side
        // because `userMemberId` is read from a cached member directory
        // that can lag behind auth state (just-joined races, anon→phone
        // upgrade, refresh in flight). Pre-fix a stale/missing entry
        // caused `myCast` to return nil after a successful cast, leaving
        // `alreadyVoted = false` and the "Emitir voto" action visible.
        // `_ = userMemberId` keeps the protocol signature stable.
        _ = userMemberId
        let rows: [VoteCast] = try await client
            .from("vote_casts")
            .select("*")
            .eq("vote_id", value: voteId.uuidString.lowercased())
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    public func counts(voteId: UUID) async throws -> VoteCounts? {
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

    public func cast(voteId: UUID, choice: VoteChoice) async throws {
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
