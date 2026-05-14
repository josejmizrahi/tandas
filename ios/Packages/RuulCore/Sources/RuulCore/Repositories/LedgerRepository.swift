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
    /// Records a new entry via direct INSERT. RLS gates by admin (mig 00078).
    /// Prefer `recordEntry(...)` which uses the `record_ledger_entry` RPC
    /// available to any group member (mig 00082).
    func record(_ entry: LedgerEntry) async throws -> LedgerEntry
    /// Records a money atom via the `record_ledger_entry` RPC (mig 00082).
    /// Any group member can call. When `resourceId` is set, the entry is
    /// scoped to that resource (event/fund/asset) per Taxonomy §29.
    func recordEntry(
        groupId: UUID,
        resourceId: UUID?,
        type: String,
        amountCents: Int64,
        fromMemberId: UUID?,
        toMemberId: UUID?,
        currency: String,
        metadata: JSONConfig
    ) async throws -> LedgerEntry

    /// Tier 6 final: records a one-tap settlement via the dedicated
    /// `record_settlement` RPC (mig 00143). Bilateral — both
    /// fromMemberId + toMemberId required, amount must be positive,
    /// both members must belong to the group. The balance projection
    /// views update automatically.
    func recordSettlement(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String,
        resourceId: UUID?,
        note: String?
    ) async throws -> LedgerEntry
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

    public func recordEntry(
        groupId: UUID,
        resourceId: UUID?,
        type: String,
        amountCents: Int64,
        fromMemberId: UUID?,
        toMemberId: UUID?,
        currency: String = "MXN",
        metadata: JSONConfig = .object([:])
    ) async throws -> LedgerEntry {
        let entry = LedgerEntry(
            groupId: groupId,
            resourceId: resourceId,
            type: type,
            amountCents: amountCents,
            currency: currency,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            metadata: metadata
        )
        entries.append(entry)
        return entry
    }

    public func recordSettlement(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String = "MXN",
        resourceId: UUID? = nil,
        note: String? = nil
    ) async throws -> LedgerEntry {
        var metadata: JSONConfig = .object([:])
        if let note, !note.isEmpty {
            metadata = .object(["note": .string(note)])
        }
        let entry = LedgerEntry(
            groupId: groupId,
            resourceId: resourceId,
            type: "settlement",
            amountCents: amountCents,
            currency: currency,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            metadata: metadata
        )
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

    public func recordEntry(
        groupId: UUID,
        resourceId: UUID?,
        type: String,
        amountCents: Int64,
        fromMemberId: UUID?,
        toMemberId: UUID?,
        currency: String = "MXN",
        metadata: JSONConfig = .object([:])
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_group_id: String
            let p_resource_id: String?
            let p_type: String
            let p_amount_cents: Int64
            let p_from_member_id: String?
            let p_to_member_id: String?
            let p_currency: String
            let p_metadata: JSONConfig
        }
        do {
            return try await client
                .rpc("record_ledger_entry", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_resource_id: resourceId?.uuidString.lowercased(),
                    p_type: type,
                    p_amount_cents: amountCents,
                    p_from_member_id: fromMemberId?.uuidString.lowercased(),
                    p_to_member_id: toMemberId?.uuidString.lowercased(),
                    p_currency: currency,
                    p_metadata: metadata
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func recordSettlement(
        groupId: UUID,
        fromMemberId: UUID,
        toMemberId: UUID,
        amountCents: Int64,
        currency: String = "MXN",
        resourceId: UUID? = nil,
        note: String? = nil
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_group_id: String
            let p_from_member_id: String
            let p_to_member_id: String
            let p_amount_cents: Int64
            let p_currency: String
            let p_resource_id: String?
            let p_note: String?
        }
        do {
            return try await client
                .rpc("record_settlement", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_from_member_id: fromMemberId.uuidString.lowercased(),
                    p_to_member_id: toMemberId.uuidString.lowercased(),
                    p_amount_cents: amountCents,
                    p_currency: currency,
                    p_resource_id: resourceId?.uuidString.lowercased(),
                    p_note: note?.isEmpty == true ? nil : note
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }
}
