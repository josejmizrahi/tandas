import Foundation
import OSLog
import Supabase

/// Row returned by `discover_pending_placeholders` (mig 00318). The iOS app
/// calls this post-login (Camino B) to surface any placeholder whose phone
/// matches the caller's verified auth.users.phone.
public struct PendingPlaceholderClaim: Identifiable, Codable, Sendable, Hashable {
    public let placeholderUid: UUID
    public let groupId: UUID
    public let groupName: String
    public let displayName: String
    public let inviteId: UUID

    public var id: UUID { placeholderUid }

    public enum CodingKeys: String, CodingKey {
        case placeholderUid = "placeholder_uid"
        case groupId        = "group_id"
        case groupName      = "group_name"
        case displayName    = "display_name"
        case inviteId       = "invite_id"
    }
}

/// Counts shown to the real owner in ClaimReviewView before they accept or
/// decline the merge. From `get_placeholder_history_summary` (mig 00318).
public struct PlaceholderHistorySummary: Codable, Sendable, Hashable {
    public let groupId: UUID
    public let memberId: UUID?
    public let fineCount: Int
    public let voteCount: Int
    public let eventCount: Int

    public enum CodingKeys: String, CodingKey {
        case groupId    = "group_id"
        case memberId   = "member_id"
        case fineCount  = "fine_count"
        case voteCount  = "vote_count"
        case eventCount = "event_count"
    }
}

/// Returned by `accept_placeholder_claim` (mig 00317).
public struct ClaimAcceptResult: Codable, Sendable, Hashable {
    public let canonicalUserId: UUID
    public let groupId: UUID
    public let memberId: UUID?

    public enum CodingKeys: String, CodingKey {
        case canonicalUserId = "canonical_user_id"
        case groupId         = "group_id"
        case memberId        = "member_id"
    }
}

public protocol ClaimRepository: Actor {
    /// Camino B: post-login the iOS client calls this to find placeholders
    /// tied to the caller's phone. Empty array when nothing pending.
    func discoverPending() async throws -> [PendingPlaceholderClaim]

    /// Pre-decision counts (fines/votes/events) attributed to the
    /// placeholder. Authorization requires caller's verified phone matches
    /// the placeholder's phone — same as Camino B accept.
    func summary(placeholderUid: UUID) async throws -> PlaceholderHistorySummary

    /// Camino A: accept via magic-link token. The token came from the
    /// WhatsApp message and is never persisted on the client.
    func acceptByToken(_ token: String) async throws -> ClaimAcceptResult

    /// Camino B: accept by placeholder uid discovered via phone match.
    func acceptByUid(_ placeholderUid: UUID) async throws -> ClaimAcceptResult

    /// Reject the merge. Placeholder is stamped disputed; admin gets a
    /// notification; placeholder membership is deactivated.
    func decline(token: String) async throws
}

// MARK: - Live

public actor LiveClaimRepository: ClaimRepository {
    private let client: SupabaseClient
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "claims")

    public init(client: SupabaseClient) { self.client = client }

    public func discoverPending() async throws -> [PendingPlaceholderClaim] {
        try await client.rpc("discover_pending_placeholders")
            .execute()
            .value
    }

    public func summary(placeholderUid: UUID) async throws -> PlaceholderHistorySummary {
        struct Params: Encodable { let p_placeholder_uid: String }
        return try await client.rpc(
            "get_placeholder_history_summary",
            params: Params(p_placeholder_uid: placeholderUid.uuidString.lowercased())
        ).execute().value
    }

    public func acceptByToken(_ token: String) async throws -> ClaimAcceptResult {
        struct Params: Encodable { let p_claim_token: String }
        return try await client.rpc(
            "accept_placeholder_claim",
            params: Params(p_claim_token: token)
        ).execute().value
    }

    public func acceptByUid(_ placeholderUid: UUID) async throws -> ClaimAcceptResult {
        struct Params: Encodable { let p_placeholder_uid: String }
        return try await client.rpc(
            "accept_placeholder_claim",
            params: Params(p_placeholder_uid: placeholderUid.uuidString.lowercased())
        ).execute().value
    }

    public func decline(token: String) async throws {
        struct Params: Encodable { let p_claim_token: String }
        _ = try await client.rpc(
            "decline_placeholder_claim",
            params: Params(p_claim_token: token)
        ).execute()
    }
}

// MARK: - Mock

public actor MockClaimRepository: ClaimRepository {
    public var pending: [PendingPlaceholderClaim] = []
    public var nextSummary: PlaceholderHistorySummary?
    public var nextAccept: ClaimAcceptResult?
    public var declineCalls: [String] = []
    public var acceptByTokenCalls: [String] = []
    public var acceptByUidCalls: [UUID] = []

    public init() {}

    public func discoverPending() async throws -> [PendingPlaceholderClaim] { pending }

    public func summary(placeholderUid: UUID) async throws -> PlaceholderHistorySummary {
        nextSummary ?? PlaceholderHistorySummary(
            groupId: UUID(), memberId: nil, fineCount: 0, voteCount: 0, eventCount: 0
        )
    }

    public func acceptByToken(_ token: String) async throws -> ClaimAcceptResult {
        acceptByTokenCalls.append(token)
        return nextAccept ?? ClaimAcceptResult(canonicalUserId: UUID(), groupId: UUID(), memberId: nil)
    }

    public func acceptByUid(_ uid: UUID) async throws -> ClaimAcceptResult {
        acceptByUidCalls.append(uid)
        return nextAccept ?? ClaimAcceptResult(canonicalUserId: UUID(), groupId: UUID(), memberId: nil)
    }

    public func decline(token: String) async throws {
        declineCalls.append(token)
    }
}
