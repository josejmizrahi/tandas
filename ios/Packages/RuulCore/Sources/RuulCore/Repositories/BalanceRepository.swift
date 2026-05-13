import Foundation
import Supabase

/// Per-member balance over `public.ledger_entries`, computed at read
/// time by the SQL views `member_balances_per_group` /
/// `member_balances_per_resource` (mig 00136 — Tier 6 slice 18).
///
/// Semantics: `netCents = receivedCents - sentCents`. Positive = the
/// member is owed; negative = the member owes. The view returns one
/// row per (scope, member, currency) — multi-currency groups land
/// multiple rows for the same member.
public struct MemberBalance: Identifiable, Codable, Sendable, Hashable {
    public let memberId: UUID
    public let currency: String
    public let sentCents: Int64
    public let receivedCents: Int64
    public let netCents: Int64

    /// Synthetic id for SwiftUI ForEach. memberId+currency is the
    /// natural composite key.
    public var id: String { "\(memberId.uuidString)|\(currency)" }

    public enum CodingKeys: String, CodingKey {
        case memberId       = "member_id"
        case currency
        case sentCents      = "sent_cents"
        case receivedCents  = "received_cents"
        case netCents       = "net_cents"
    }

    public init(memberId: UUID, currency: String, sentCents: Int64, receivedCents: Int64, netCents: Int64) {
        self.memberId = memberId
        self.currency = currency
        self.sentCents = sentCents
        self.receivedCents = receivedCents
        self.netCents = netCents
    }
}

public enum BalanceError: Error, Equatable {
    case rpcFailed(String)
}

public protocol BalanceRepository: Actor {
    /// Net balances for every member of a group. Empty array when no
    /// ledger entries exist yet.
    func balancesForGroup(_ groupId: UUID) async throws -> [MemberBalance]

    /// Net balances scoped to a single resource (event / booking / fund).
    /// Excludes group-level entries — only counts ledger rows whose
    /// `resource_id` matches. Empty when the resource has no money flow.
    func balancesForResource(_ resourceId: UUID) async throws -> [MemberBalance]
}

// MARK: - Mock

public actor MockBalanceRepository: BalanceRepository {
    private var perGroup: [UUID: [MemberBalance]]
    private var perResource: [UUID: [MemberBalance]]

    public init(
        perGroupSeed: [UUID: [MemberBalance]] = [:],
        perResourceSeed: [UUID: [MemberBalance]] = [:]
    ) {
        self.perGroup = perGroupSeed
        self.perResource = perResourceSeed
    }

    public func balancesForGroup(_ groupId: UUID) async throws -> [MemberBalance] {
        perGroup[groupId] ?? []
    }

    public func balancesForResource(_ resourceId: UUID) async throws -> [MemberBalance] {
        perResource[resourceId] ?? []
    }

    /// Test helper: install a snapshot for a group/resource so views
    /// asserting on balances can exercise the rendering path without
    /// spinning up the SQL view.
    public func stubGroup(_ groupId: UUID, balances: [MemberBalance]) {
        perGroup[groupId] = balances
    }
    public func stubResource(_ resourceId: UUID, balances: [MemberBalance]) {
        perResource[resourceId] = balances
    }
}

// MARK: - Live

public actor LiveBalanceRepository: BalanceRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func balancesForGroup(_ groupId: UUID) async throws -> [MemberBalance] {
        do {
            return try await client
                .from("member_balances_per_group")
                .select("member_id, currency, sent_cents, received_cents, net_cents")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw BalanceError.rpcFailed(error.localizedDescription)
        }
    }

    public func balancesForResource(_ resourceId: UUID) async throws -> [MemberBalance] {
        do {
            return try await client
                .from("member_balances_per_resource")
                .select("member_id, currency, sent_cents, received_cents, net_cents")
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw BalanceError.rpcFailed(error.localizedDescription)
        }
    }
}
