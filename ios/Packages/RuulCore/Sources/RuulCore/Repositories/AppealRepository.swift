import Foundation
import Supabase

/// Read + lifecycle for fine appeals + voting. Sprint 1c builds the UI.
public protocol AppealRepository: Actor {
    /// All appeals for a group (active + resolved), ordered by recency.
    func appeals(for groupId: UUID) async throws -> [Appeal]
    /// Appeal by id, or nil if not visible to caller.
    func appeal(id: UUID) async throws -> Appeal?
    /// Most-recent appeal for a given fine, regardless of status. Used by
    /// FineDetailView to know whether to show "Apelar" or "Ver apelación".
    func appealForFine(fineId: UUID) async throws -> Appeal?
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

    public func appealForFine(fineId: UUID) async throws -> Appeal? {
        appealsStore
            .filter { $0.fineId == fineId }
            .sorted { $0.createdAt > $1.createdAt }
            .first
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

/// Live impl backed by the generic votes/vote_casts schema (00020 + 00023).
/// The legacy `appeals` / `appeal_votes` tables were dropped in migration
/// 00047; all fine appeals now live as `votes(vote_type='fine_appeal')`
/// with the infractor's member_id in `payload.member_id` and the appellant
/// reason in `payload.reason`. This actor translates that wire shape back
/// to the V1 `Appeal` / `AppealVote` / `AppealVoteCounts` model the UI
/// already speaks. The protocol surface is unchanged.
public actor LiveAppealRepository: AppealRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    // MARK: - Wire types

    /// Projection of `public.votes` row filtered to vote_type='fine_appeal'.
    /// Translates to `Appeal` via `toAppeal()`.
    private struct VoteRow: Decodable {
        let id: UUID
        let groupId: UUID
        let voteType: String
        let referenceId: UUID
        let title: String?
        let description: String?
        let createdByMemberId: UUID
        let openedAt: Date
        let closesAt: Date
        let resolvedAt: Date?
        let status: String
        let payload: PayloadProjection?
        let counts: CountsProjection?
        let createdAt: Date
        let updatedAt: Date

        struct PayloadProjection: Decodable {
            let memberId: UUID?
            let reason: String?
            enum CodingKeys: String, CodingKey {
                case memberId = "member_id"
                case reason
            }
        }

        struct CountsProjection: Decodable {
            let inFavor: Int
            let against: Int
            let abstained: Int
            let pending: Int
            let totalEligible: Int
            let resolution: String?

            enum CodingKeys: String, CodingKey {
                case inFavor       = "inFavor"
                case against       = "against"
                case abstained     = "abstained"
                case pending       = "pending"
                case totalEligible = "totalEligible"
                case resolution    = "resolution"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case groupId            = "group_id"
            case voteType           = "vote_type"
            case referenceId        = "reference_id"
            case title
            case description
            case createdByMemberId  = "created_by_member_id"
            case openedAt           = "opened_at"
            case closesAt           = "closes_at"
            case resolvedAt         = "resolved_at"
            case status
            case payload
            case counts
            case createdAt          = "created_at"
            case updatedAt          = "updated_at"
        }

        func toAppeal() -> Appeal {
            // payload.member_id is the infractor's member_id (= appellant for
            // fine_appeal). For votes seeded before payload was populated
            // (none in prod, but defensive), fall back to the vote creator.
            let appellantMemberId = payload?.memberId ?? createdByMemberId
            let reasonText        = payload?.reason ?? description ?? ""

            return Appeal(
                id:                  id,
                fineId:              referenceId,
                appellantMemberId:   appellantMemberId,
                reason:              reasonText,
                status:              mapStatus(),
                votingStartedAt:     openedAt,
                votingEndsAt:        closesAt,
                resolvedAt:          resolvedAt,
                voteCounts:          counts.map { c in
                    AppealVoteCounts(
                        inFavor:       c.inFavor,
                        against:       c.against,
                        abstained:     c.abstained,
                        pending:       c.pending,
                        totalEligible: c.totalEligible
                    )
                },
                createdAt:           createdAt,
                updatedAt:           updatedAt
            )
        }

        private func mapStatus() -> AppealStatus {
            switch status {
            case "open":
                return .voting
            case "resolved":
                if let resolution = counts?.resolution {
                    if resolution == "passed" { return .resolvedInFavor }
                    if resolution == "failed" { return .resolvedAgainst }
                }
                return .expired
            case "quorum_failed":
                return .expired
            default:
                return .voting
            }
        }
    }

    private struct CastRow: Decodable {
        let id: UUID
        let voteId: UUID
        let memberId: UUID
        let choice: String
        let castAt: Date?
        let createdAt: Date
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case voteId    = "vote_id"
            case memberId  = "member_id"
            case choice
            case castAt    = "cast_at"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    // MARK: - Reads

    public func appeals(for groupId: UUID) async throws -> [Appeal] {
        let rows: [VoteRow] = try await client
            .from("votes")
            .select("*")
            .eq("vote_type", value: "fine_appeal")
            .eq("group_id",  value: groupId.uuidString.lowercased())
            .order("created_at", ascending: false)
            .execute()
            .value
        return rows.map { $0.toAppeal() }
    }

    public func appeal(id: UUID) async throws -> Appeal? {
        let row: VoteRow? = try? await client
            .from("votes")
            .select("*")
            .eq("id",        value: id.uuidString.lowercased())
            .eq("vote_type", value: "fine_appeal")
            .single()
            .execute()
            .value
        return row?.toAppeal()
    }

    public func appealForFine(fineId: UUID) async throws -> Appeal? {
        let rows: [VoteRow] = (try? await client
            .from("votes")
            .select("*")
            .eq("vote_type",    value: "fine_appeal")
            .eq("reference_id", value: fineId.uuidString.lowercased())
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value) ?? []
        return rows.first?.toAppeal()
    }

    /// `voteCounts` reads `votes.counts` jsonb when the vote is resolved
    /// (finalize_vote populates it). For open votes, aggregates `vote_casts`
    /// directly so the UI can show a live tally during voting.
    public func voteCounts(appealId: UUID) async throws -> AppealVoteCounts? {
        let row: VoteRow? = try? await client
            .from("votes")
            .select("*")
            .eq("id", value: appealId.uuidString.lowercased())
            .single()
            .execute()
            .value

        if let counts = row?.counts {
            return AppealVoteCounts(
                inFavor:       counts.inFavor,
                against:       counts.against,
                abstained:     counts.abstained,
                pending:       counts.pending,
                totalEligible: counts.totalEligible
            )
        }

        // Open vote: aggregate vote_casts. Anonymized in spirit because we
        // never expose individual ballot rows, only counts.
        struct ChoiceOnly: Decodable { let choice: String }
        let casts: [ChoiceOnly] = (try? await client
            .from("vote_casts")
            .select("choice")
            .eq("vote_id", value: appealId.uuidString.lowercased())
            .execute()
            .value) ?? []

        guard !casts.isEmpty else { return nil }

        let inFavor   = casts.filter { $0.choice == "in_favor"   }.count
        let against   = casts.filter { $0.choice == "against"    }.count
        let abstained = casts.filter { $0.choice == "abstained"  }.count
        let pending   = casts.filter { $0.choice == "pending"    }.count

        return AppealVoteCounts(
            inFavor:       inFavor,
            against:       against,
            abstained:     abstained,
            pending:       pending,
            totalEligible: casts.count
        )
    }

    public func myVote(appealId: UUID, userMemberId: UUID) async throws -> AppealVote? {
        let row: CastRow? = try? await client
            .from("vote_casts")
            .select("*")
            .eq("vote_id",   value: appealId.uuidString.lowercased())
            .eq("member_id", value: userMemberId.uuidString.lowercased())
            .single()
            .execute()
            .value
        guard let row, let choice = AppealVoteChoice(rawValue: row.choice) else {
            return nil
        }
        return AppealVote(
            id:        row.id,
            appealId:  row.voteId,
            memberId:  row.memberId,
            choice:    choice,
            votedAt:   row.castAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    // MARK: - Writes

    public func startAppeal(fineId: UUID, reason: String) async throws -> UUID {
        struct Params: Encodable {
            let p_fine_id: String
            let p_reason:  String
        }
        return try await client
            .rpc("start_fine_appeal", params: Params(
                p_fine_id: fineId.uuidString.lowercased(),
                p_reason:  reason
            ))
            .execute()
            .value
    }

    public func castVote(appealId: UUID, choice: AppealVoteChoice) async throws {
        // cast_vote rejects 'pending' (00020:373). Only the three real
        // choices are valid. The UI never invokes this with .pending.
        struct Params: Encodable {
            let p_vote_id: String
            let p_choice:  String
        }
        try await client
            .rpc("cast_vote", params: Params(
                p_vote_id: appealId.uuidString.lowercased(),
                p_choice:  choice.rawValue
            ))
            .execute()
    }

    public func closeVote(appealId: UUID) async throws -> AppealStatus {
        // finalize_vote returns text resolution: 'passed' | 'failed' |
        // 'quorum_failed'. Map to AppealStatus the UI expects.
        struct Params: Encodable { let p_vote_id: String }
        let resolution: String = try await client
            .rpc("finalize_vote", params: Params(
                p_vote_id: appealId.uuidString.lowercased()
            ))
            .execute()
            .value
        switch resolution {
        case "passed": return .resolvedInFavor
        case "failed": return .resolvedAgainst
        default:       return .expired   // 'quorum_failed' or unknown
        }
    }
}
