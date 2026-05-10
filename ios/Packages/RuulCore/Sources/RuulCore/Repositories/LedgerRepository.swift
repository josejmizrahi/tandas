import Foundation
import Supabase

public enum LedgerError: Error, Equatable {
    case rpcFailed(String)
}

/// Reads/writes for `public.ledger_entries` (atom log).
///
/// Ledger entries are append-only at the spec level. Callers SHOULD only
/// insert, never update. This repo intentionally exposes no update/delete
/// to enforce the invariant on the iOS side.
public protocol LedgerRepository: Actor {
    /// All ledger entries for a group, newest first. Used for the
    /// group-wide money feed.
    func list(groupId: UUID, limit: Int) async throws -> [LedgerEntry]
    /// Entries scoped to a specific resource (event, fund, booking).
    /// Powers the per-resource Money section.
    func listForResource(_ resourceId: UUID, limit: Int) async throws -> [LedgerEntry]
    /// Entries involving a specific member (either side).
    func listForMember(_ memberId: UUID, limit: Int) async throws -> [LedgerEntry]
    /// Records a new entry. RLS gates by admin (mig 00078). Phase 3 may
    /// add a SECURITY DEFINER `record_*` RPC family for finer per-action
    /// gating.
    func record(_ entry: LedgerEntry) async throws -> LedgerEntry
}

// MARK: - Mock

public actor MockLedgerRepository: LedgerRepository {
    private var entries: [LedgerEntry]

    public init(seed: [LedgerEntry] = []) { self.entries = seed }

    public func list(groupId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        entries.filter { $0.groupId == groupId }.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }

    public func listForResource(_ resourceId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        entries.filter { $0.resourceId == resourceId }.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        entries.filter { $0.fromMemberId == memberId || $0.toMemberId == memberId }
            .sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { $0 }
    }

    public func record(_ entry: LedgerEntry) async throws -> LedgerEntry {
        entries.append(entry)
        return entry
    }
}

// MARK: - Live

public actor LiveLedgerRepository: LedgerRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func list(groupId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        do {
            return try await client
                .from("ledger_entries")
                .select("*")
                .eq("group_id", value: groupId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForResource(_ resourceId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        do {
            return try await client
                .from("ledger_entries")
                .select("*")
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 200) async throws -> [LedgerEntry] {
        do {
            // Two queries (from + to) merged client-side. Postgrest doesn't
            // support OR across columns natively without rpc.
            async let fromTask: [LedgerEntry] = client
                .from("ledger_entries")
                .select("*")
                .eq("from_member_id", value: memberId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            async let toTask: [LedgerEntry] = client
                .from("ledger_entries")
                .select("*")
                .eq("to_member_id", value: memberId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            let (fromEntries, toEntries) = try await (fromTask, toTask)
            let combined = (fromEntries + toEntries)
            // De-dup + re-sort by occurredAt desc.
            var seen: Set<UUID> = []
            return combined.filter { entry in
                if seen.contains(entry.id) { return false }
                seen.insert(entry.id)
                return true
            }.sorted { $0.occurredAt > $1.occurredAt }
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func record(_ entry: LedgerEntry) async throws -> LedgerEntry {
        do {
            return try await client
                .from("ledger_entries")
                .insert(entry)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }
}
