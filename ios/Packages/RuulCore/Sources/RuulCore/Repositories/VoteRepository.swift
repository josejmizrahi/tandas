import Foundation
import Supabase

/// Generic vote operations. Wraps `public.votes` reads + the RPCs
/// `start_vote`, `finalize_vote` (cast goes through `VoteCastRepository`).
///
/// V1 only uses `vote_type = .fineAppeal`. V2+ adds rule_change /
/// member_removal / fund_withdrawal / etc. without changing this protocol —
/// the Vote model + `vote_type` enum already supports them.
public protocol VoteRepository: Actor {
    /// All votes for a group (open + resolved), ordered by recency.
    func votes(for groupId: UUID) async throws -> [Vote]
    /// Open votes for a group (status = 'open').
    func openVotes(for groupId: UUID) async throws -> [Vote]
    /// Vote by id, or nil if not visible to caller.
    func vote(id: UUID) async throws -> Vote?
    /// Most-recent vote for a given reference (e.g. appeal_id), regardless
    /// of status. Used to resolve "is there already a vote on this?".
    func voteForReference(referenceId: UUID) async throws -> Vote?

    /// Starts a vote via `start_vote` RPC. Server seeds eligible voters +
    /// emits `voteOpened`. Returns the new vote id. `payload` is opaque
    /// vote-type-specific context.
    func startVote(
        groupId: UUID,
        voteType: VoteType,
        referenceId: UUID,
        title: String,
        description: String?,
        payload: JSONConfig
    ) async throws -> UUID

    /// Forces resolution via `finalize_vote` RPC (normally called by the
    /// cron `finalize-votes` when closes_at passes). Returns the
    /// resolution: passed | failed | quorum_failed.
    func finalizeVote(voteId: UUID) async throws -> VoteResolution

    /// Cancels an open vote via `cancel_vote` RPC. Only the vote creator
    /// may cancel, and only while no real (non-pending) casts exist.
    func cancelVote(_ voteId: UUID) async throws
}

// MARK: - Mock

public actor MockVoteRepository: VoteRepository {
    private var store: [Vote] = []
    public var nextStartError: Error?
    public var nextFinalizeError: Error?
    public var nextOpenVotesError: Error?

    /// Recorded args for each `startVote(...)` call. Tests assert against
    /// this to verify wiring (vote_type, title, payload, etc.).
    public struct StartVoteCall: Sendable {
        public let groupId: UUID
        public let voteType: VoteType
        public let referenceId: UUID
        public let title: String
        public let description: String?
        public let payload: JSONConfig
    }
    public private(set) var startVoteCalls: [StartVoteCall] = []

    public init(seed: [Vote] = []) { self.store = seed }

    public func setNextStartError(_ error: Error?) { self.nextStartError = error }
    public func setNextFinalizeError(_ error: Error?) { self.nextFinalizeError = error }
    public func setNextOpenVotesError(_ error: Error?) { self.nextOpenVotesError = error }

    public func votes(for groupId: UUID) async throws -> [Vote] {
        store.filter { $0.groupId == groupId }.sorted { $0.openedAt > $1.openedAt }
    }

    public func openVotes(for groupId: UUID) async throws -> [Vote] {
        if let err = nextOpenVotesError { nextOpenVotesError = nil; throw err }
        return store.filter { $0.groupId == groupId && $0.status == .open }.sorted { $0.openedAt > $1.openedAt }
    }

    public func vote(id: UUID) async throws -> Vote? {
        store.first { $0.id == id }
    }

    public func voteForReference(referenceId: UUID) async throws -> Vote? {
        store.filter { $0.referenceId == referenceId }
             .sorted { $0.openedAt > $1.openedAt }
             .first
    }

    public func startVote(
        groupId: UUID,
        voteType: VoteType,
        referenceId: UUID,
        title: String,
        description: String?,
        payload: JSONConfig
    ) async throws -> UUID {
        startVoteCalls.append(StartVoteCall(
            groupId: groupId,
            voteType: voteType,
            referenceId: referenceId,
            title: title,
            description: description,
            payload: payload
        ))
        if let err = nextStartError { nextStartError = nil; throw err }
        let v = Vote(
            id: UUID(),
            groupId: groupId,
            voteType: voteType,
            referenceId: referenceId,
            title: title,
            description: description,
            createdByMemberId: nil,
            openedAt: .now,
            closesAt: .now.addingTimeInterval(72 * 3600),
            resolvedAt: nil,
            quorumPercent: 50,
            thresholdPercent: 50,
            isAnonymous: true,
            status: .open,
            counts: nil,
            payload: payload
        )
        store.append(v)
        return v.id
    }

    public func finalizeVote(voteId: UUID) async throws -> VoteResolution {
        if let err = nextFinalizeError { nextFinalizeError = nil; throw err }
        guard let idx = store.firstIndex(where: { $0.id == voteId }) else {
            throw NSError(domain: "MockVote", code: 404)
        }
        var v = store[idx]
        v.status = .resolved
        v.resolvedAt = .now
        store[idx] = v
        return .passed
    }

    public func cancelVote(_ voteId: UUID) async throws {
        guard let idx = store.firstIndex(where: { $0.id == voteId }) else { return }
        var v = store[idx]
        v.status = .cancelled
        v.resolvedAt = .now
        store[idx] = v
    }
}

// MARK: - Live

public actor LiveVoteRepository: VoteRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func votes(for groupId: UUID) async throws -> [Vote] {
        try await client
            .from("votes")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("opened_at", ascending: false)
            .execute()
            .value
    }

    public func openVotes(for groupId: UUID) async throws -> [Vote] {
        try await client
            .from("votes")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("status", value: VoteStatus.open.rawValue)
            .order("opened_at", ascending: false)
            .execute()
            .value
    }

    public func vote(id: UUID) async throws -> Vote? {
        let rows: [Vote] = try await client
            .from("votes")
            .select("*")
            .eq("id", value: id.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    public func voteForReference(referenceId: UUID) async throws -> Vote? {
        let rows: [Vote] = try await client
            .from("votes")
            .select("*")
            .eq("reference_id", value: referenceId.uuidString.lowercased())
            .order("opened_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    public func startVote(
        groupId: UUID,
        voteType: VoteType,
        referenceId: UUID,
        title: String,
        description: String?,
        payload: JSONConfig
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_group_id: String
            let p_vote_type: String
            let p_reference_id: String
            let p_title: String
            let p_description: String?
            let p_payload: JSONConfig
        }
        let params = Params(
            p_group_id:     groupId.uuidString.lowercased(),
            p_vote_type:    voteType.rawValue,
            p_reference_id: referenceId.uuidString.lowercased(),
            p_title:        title,
            p_description:  description,
            p_payload:      payload
        )
        let voteId: UUID = try await client
            .rpc("start_vote", params: params)
            .execute()
            .value
        return voteId
    }

    public func finalizeVote(voteId: UUID) async throws -> VoteResolution {
        struct Params: Encodable { let p_vote_id: String }
        let params = Params(p_vote_id: voteId.uuidString.lowercased())
        let resolutionRaw: String = try await client
            .rpc("finalize_vote", params: params)
            .execute()
            .value
        return VoteResolution(rawValue: resolutionRaw) ?? .quorumFailed
    }

    public func cancelVote(_ voteId: UUID) async throws {
        struct Params: Encodable { let p_vote_id: String }
        let params = Params(p_vote_id: voteId.uuidString.lowercased())
        try await client
            .rpc("cancel_vote", params: params)
            .execute()
    }
}
