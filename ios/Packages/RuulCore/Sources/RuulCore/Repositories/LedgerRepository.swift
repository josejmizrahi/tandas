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
    /// `record_settlement` RPC (mig 00145). Bilateral — both
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

    /// SharedMoney P3: per-(member, currency) net positions in a group,
    /// derived from `member_balances_per_group` (mig 00136). Powers the
    /// "Tu posición" card on GroupSpaceView + the
    /// `GroupBalancesView` subscreen ("Te deben / Debes").
    func balancesForGroup(_ groupId: UUID) async throws -> [MemberGroupBalance]

    /// SharedMoney P9: returns the viewer's own balance rows across
    /// every group in `groupIds`. Powers the cross-group obligations
    /// roll-up on the Home tab. Implementation walks
    /// `group_members` → `member_balances_per_group` filtered to the
    /// viewer's `user_id`. Returns only rows where the viewer is a
    /// member of the given group AND has non-zero history (the view
    /// only emits rows for members with at least one ledger entry).
    func myBalancesAcrossGroups(
        userId: UUID,
        groupIds: [UUID]
    ) async throws -> [MemberGroupBalance]

    /// Edit foundation (mig 00368): appends a settlement-shaped
    /// "undo" entry that neutralizes the original on every projection.
    /// Caller must be the original `recorded_by`. Idempotent via
    /// `clientId` (stamped into `metadata.client_id`). Returns the
    /// inserted reverse entry — callers should reload affected views.
    func reverseEntry(
        entryId: UUID,
        reason: String?,
        clientId: UUID
    ) async throws -> LedgerEntry

    /// Mig 00372: in-place edit of the entry's note field. The atom
    /// log stays immutable for math (amount/from/to/type) — only the
    /// descriptive note is mutable. Updates both `ledger_entries` and
    /// the originating `system_events.payload` so the activity feed
    /// reflects the new text on next refresh. Pass nil/empty to clear.
    func updateEntryNote(
        entryId: UUID,
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

    public func myBalancesAcrossGroups(
        userId: UUID,
        groupIds: [UUID]
    ) async throws -> [MemberGroupBalance] {
        // Mock doesn't model user→member membership, so the in-memory
        // implementation can't filter to "the viewer's row". Returns
        // empty — previews + tests just hide the card. The Live path
        // does the real two-query walk.
        []
    }

    public func updateEntryNote(
        entryId: UUID,
        note: String?
    ) async throws -> LedgerEntry {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else {
            throw LedgerError.rpcFailed("entry not found")
        }
        var meta: [String: JSONConfig] = {
            if case .object(let dict) = entries[idx].metadata { return dict }
            return [:]
        }()
        let trimmed = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            meta.removeValue(forKey: "note")
        } else {
            meta["note"] = .string(trimmed)
        }
        let original = entries[idx]
        let updated = LedgerEntry(
            id: original.id,
            groupId: original.groupId,
            resourceId: original.resourceId,
            type: original.type,
            amountCents: original.amountCents,
            currency: original.currency,
            fromMemberId: original.fromMemberId,
            toMemberId: original.toMemberId,
            metadata: .object(meta),
            occurredAt: original.occurredAt,
            recordedAt: original.recordedAt,
            recordedBy: original.recordedBy
        )
        entries[idx] = updated
        return updated
    }

    public func reverseEntry(
        entryId: UUID,
        reason: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        // Mock: append a settlement-shaped entry with the same
        // metadata convention so the in-memory store reflects the
        // reversal. The math holds because MockLedgerRepository's
        // `balancesForGroup` sums by from/to across all types — the
        // flipped from/to cancels the original.
        guard let original = entries.first(where: { $0.id == entryId }) else {
            throw LedgerError.rpcFailed("entry not found")
        }
        var meta: [String: JSONConfig] = [
            "reversed_ledger_entry_id": .string(entryId.uuidString.lowercased()),
            "reversed_original_type": .string(original.type),
            "client_id": .string(clientId.uuidString.lowercased())
        ]
        if let reason, !reason.isEmpty {
            meta["reason"] = .string(reason)
        }
        let reverse = LedgerEntry(
            groupId: original.groupId,
            resourceId: original.resourceId,
            type: "settlement",
            amountCents: original.amountCents,
            currency: original.currency,
            fromMemberId: original.toMemberId,
            toMemberId: original.fromMemberId,
            metadata: .object(meta)
        )
        entries.append(reverse)
        return reverse
    }

    public func balancesForGroup(_ groupId: UUID) async throws -> [MemberGroupBalance] {
        // Mock aggregates from in-memory entries by (member_id,
        // currency). Mirrors the server view's math: sent = sum where
        // member is `from_member_id`, received = sum where member is
        // `to_member_id`, net = received - sent.
        var sent: [String: Int64] = [:]
        var received: [String: Int64] = [:]
        for e in entries where e.groupId == groupId {
            if let m = e.fromMemberId {
                sent["\(m.uuidString)|\(e.currency)", default: 0] += e.amountCents
            }
            if let m = e.toMemberId {
                received["\(m.uuidString)|\(e.currency)", default: 0] += e.amountCents
            }
        }
        let keys = Set(sent.keys).union(received.keys)
        return keys.compactMap { key -> MemberGroupBalance? in
            let parts = key.split(separator: "|")
            guard parts.count == 2,
                  let memberId = UUID(uuidString: String(parts[0])) else { return nil }
            let currency = String(parts[1])
            let s = sent[key] ?? 0
            let r = received[key] ?? 0
            return MemberGroupBalance(
                groupId: groupId,
                memberId: memberId,
                currency: currency,
                sentCents: s,
                receivedCents: r,
                netCents: r - s
            )
        }
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

    public func balancesForGroup(_ groupId: UUID) async throws -> [MemberGroupBalance] {
        do {
            return try await client
                .from("member_balances_per_group")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func reverseEntry(
        entryId: UUID,
        reason: String?,
        clientId: UUID
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_entry_id: String
            let p_reason: String?
            let p_client_id: String
        }
        do {
            return try await client
                .rpc("reverse_ledger_entry", params: Params(
                    p_entry_id: entryId.uuidString.lowercased(),
                    p_reason: (reason?.isEmpty == false) ? reason : nil,
                    p_client_id: clientId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateEntryNote(
        entryId: UUID,
        note: String?
    ) async throws -> LedgerEntry {
        struct Params: Encodable {
            let p_entry_id: String
            let p_note: String?
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            return try await client
                .rpc("update_ledger_entry_note", params: Params(
                    p_entry_id: entryId.uuidString.lowercased(),
                    p_note: cleaned
                ))
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }

    public func myBalancesAcrossGroups(
        userId: UUID,
        groupIds: [UUID]
    ) async throws -> [MemberGroupBalance] {
        guard !groupIds.isEmpty else { return [] }
        do {
            // Step 1: resolve the viewer's `group_members.id` per group.
            // RLS allows reading own membership rows.
            struct MembershipRow: Decodable {
                let id: UUID
            }
            let groupIdStrings = groupIds.map { $0.uuidString.lowercased() }
            let memberships: [MembershipRow] = try await client
                .from("group_members")
                .select("id")
                .eq("user_id", value: userId.uuidString.lowercased())
                .in("group_id", values: groupIdStrings)
                .execute()
                .value
            let memberIds = memberships.map { $0.id.uuidString.lowercased() }
            guard !memberIds.isEmpty else { return [] }

            // Step 2: read balance rows for those member ids. The view's
            // composite key already includes group_id so no extra
            // disambiguation is needed.
            return try await client
                .from("member_balances_per_group")
                .select()
                .in("member_id", values: memberIds)
                .execute()
                .value
        } catch {
            throw LedgerError.rpcFailed(error.localizedDescription)
        }
    }
}
