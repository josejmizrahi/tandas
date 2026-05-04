import Foundation
import Supabase

/// Read + lifecycle for fine appeals + voting. Sprint 1c builds the UI.
public protocol AppealRepository: Actor {
    /// All appeals for a group (active + resolved), ordered by recency.
    func appeals(for groupId: UUID) async throws -> [Appeal]
    /// Appeal by id, or nil if not visible to caller.
    func appeal(id: UUID) async throws -> Appeal?
    /// Aggregated counts for an appeal — anonymized via the
    /// `appeal_vote_counts` view, never raw ballot rows.
    func voteCounts(appealId: UUID) async throws -> AppealVoteCounts?
    /// The caller's own ballot for an appeal, if eligible.
    func myVote(appealId: UUID, userMemberId: UUID) async throws -> AppealVote?

    /// Starts a new appeal via `start_appeal` RPC. Server seeds eligible
    /// voters and emits `appealCreated`.
    func startAppeal(fineId: UUID, reason: String) async throws -> UUID
    /// Casts the caller's vote via `cast_appeal_vote` RPC.
    func castVote(appealId: UUID, choice: AppealVoteChoice) async throws
    /// Server-only call (cron or admin tool) to finalize voting.
    func closeVote(appealId: UUID) async throws -> AppealStatus
}

// MARK: - Mock

public actor MockAppealRepository: AppealRepository {
    public private(set) var appealsStore: [Appeal] = []
    public private(set) var votesStore: [AppealVote] = []

    public init(seed: [Appeal] = []) { self.appealsStore = seed }

    public func appeals(for groupId: UUID) async throws -> [Appeal] {
        appealsStore.sorted { $0.createdAt > $1.createdAt }
    }

    public func appeal(id: UUID) async throws -> Appeal? {
        appealsStore.first { $0.id == id }
    }

    public func voteCounts(appealId: UUID) async throws -> AppealVoteCounts? {
        let votes = votesStore.filter { $0.appealId == appealId }
        guard !votes.isEmpty else { return nil }
        return AppealVoteCounts(
            inFavor:       votes.filter { $0.choice == .inFavor }.count,
            against:       votes.filter { $0.choice == .against }.count,
            abstained:     votes.filter { $0.choice == .abstained }.count,
            pending:       votes.filter { $0.choice == .pending }.count,
            totalEligible: votes.count
        )
    }

    public func myVote(appealId: UUID, userMemberId: UUID) async throws -> AppealVote? {
        votesStore.first { $0.appealId == appealId && $0.memberId == userMemberId }
    }

    public func startAppeal(fineId: UUID, reason: String) async throws -> UUID {
        let appeal = Appeal(
            fineId: fineId,
            appellantMemberId: UUID(),
            reason: reason,
            votingEndsAt: Date.now.addingTimeInterval(72 * 3600)
        )
        appealsStore.append(appeal)
        return appeal.id
    }

    public func castVote(appealId: UUID, choice: AppealVoteChoice) async throws {
        // Mock: append a fake vote row each call
        votesStore.append(AppealVote(
            id: UUID(),
            appealId: appealId,
            memberId: UUID(),
            choice: choice,
            votedAt: .now,
            createdAt: .now,
            updatedAt: .now
        ))
    }

    public func closeVote(appealId: UUID) async throws -> AppealStatus {
        guard let idx = appealsStore.firstIndex(where: { $0.id == appealId }) else {
            return .expired
        }
        let counts = try await voteCounts(appealId: appealId)
        let outcome: AppealStatus = (counts?.inFavor ?? 0) > (counts?.against ?? 0)
            ? .resolvedInFavor : .resolvedAgainst
        let original = appealsStore[idx]
        appealsStore[idx] = Appeal(
            id: original.id,
            fineId: original.fineId,
            appellantMemberId: original.appellantMemberId,
            reason: original.reason,
            status: outcome,
            votingStartedAt: original.votingStartedAt,
            votingEndsAt: original.votingEndsAt,
            resolvedAt: .now,
            voteCounts: counts,
            createdAt: original.createdAt,
            updatedAt: .now
        )
        return outcome
    }
}

// MARK: - Live

public actor LiveAppealRepository: AppealRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func appeals(for groupId: UUID) async throws -> [Appeal] {
        // appeals filter by group via fine; RLS already restricts to member rows
        try await client
            .from("appeals")
            .select("*")
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func appeal(id: UUID) async throws -> Appeal? {
        try? await client
            .from("appeals")
            .select("*")
            .eq("id", value: id.uuidString.lowercased())
            .single()
            .execute()
            .value
    }

    public func voteCounts(appealId: UUID) async throws -> AppealVoteCounts? {
        struct Row: Codable {
            let appealId: UUID
            let inFavor: Int
            let against: Int
            let abstained: Int
            let pending: Int
            let totalEligible: Int
            enum CodingKeys: String, CodingKey {
                case appealId = "appeal_id"
                case inFavor = "in_favor"
                case against
                case abstained
                case pending
                case totalEligible = "total_eligible"
            }
        }
        let row: Row? = try? await client
            .from("appeal_vote_counts")
            .select("*")
            .eq("appeal_id", value: appealId.uuidString.lowercased())
            .single()
            .execute()
            .value
        guard let row else { return nil }
        return AppealVoteCounts(
            inFavor: row.inFavor,
            against: row.against,
            abstained: row.abstained,
            pending: row.pending,
            totalEligible: row.totalEligible
        )
    }

    public func myVote(appealId: UUID, userMemberId: UUID) async throws -> AppealVote? {
        try? await client
            .from("appeal_votes")
            .select("*")
            .eq("appeal_id", value: appealId.uuidString.lowercased())
            .eq("member_id", value: userMemberId.uuidString.lowercased())
            .single()
            .execute()
            .value
    }

    public func startAppeal(fineId: UUID, reason: String) async throws -> UUID {
        struct Params: Encodable {
            let p_fine_id: String
            let p_reason: String
        }
        return try await client
            .rpc("start_appeal", params: Params(
                p_fine_id: fineId.uuidString.lowercased(),
                p_reason: reason
            ))
            .execute()
            .value
    }

    public func castVote(appealId: UUID, choice: AppealVoteChoice) async throws {
        struct Params: Encodable {
            let p_appeal_id: String
            let p_choice: String
        }
        try await client
            .rpc("cast_appeal_vote", params: Params(
                p_appeal_id: appealId.uuidString.lowercased(),
                p_choice: choice.rawValue
            ))
            .execute()
    }

    public func closeVote(appealId: UUID) async throws -> AppealStatus {
        struct Params: Encodable { let p_appeal_id: String }
        let outcome: String = try await client
            .rpc("close_appeal_vote", params: Params(
                p_appeal_id: appealId.uuidString.lowercased()
            ))
            .execute()
            .value
        return AppealStatus(rawValue: outcome) ?? .expired
    }
}
