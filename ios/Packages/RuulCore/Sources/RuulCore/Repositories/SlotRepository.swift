import Foundation
import Supabase

public enum SlotError: Error, Equatable {
    case rpcFailed(String)
    case notFound
    case decodeFailed(String)
}

/// Typed read surface for `resource_type='slot'`. Reads come from the
/// polymorphic `public.resources` table filtered by resource_type and
/// decoded via `ResourceRow.decodeAsSlot()`.
///
/// **Writes are NOT here.** Slot lifecycle (create, assign, book, swap)
/// lives in `SlotLifecycleRepository`, which calls the dedicated RPCs
/// from mig 00070 (`create_slot`, `assign_slot`, `book_slot`,
/// `request_slot_swap`). The wizard-driven path also routes through
/// `ResourceDraftRepository.build` (mig 00204 `when 'slot'` branch).
/// This repo just gives the read side a typed front door.
public protocol SlotRepository: Actor {
    /// All non-archived slots for a group, ordered by `starts_at` ascending.
    func listForGroup(_ groupId: UUID) async throws -> [Slot]

    /// Slots that belong to a single parent asset, ordered by `starts_at`.
    func listForAsset(_ assetId: UUID) async throws -> [Slot]

    /// Single slot by id. Throws `notFound` if missing or archived.
    func get(_ slotId: UUID) async throws -> Slot
}

// MARK: - Mock

public actor MockSlotRepository: SlotRepository {
    private var slots: [Slot]

    public init(seed: [Slot] = []) { self.slots = seed }

    public func listForGroup(_ groupId: UUID) async throws -> [Slot] {
        slots
            .filter { $0.groupId == groupId && $0.archivedAt == nil }
            .sorted { $0.startsAt < $1.startsAt }
    }

    public func listForAsset(_ assetId: UUID) async throws -> [Slot] {
        slots
            .filter { $0.assetId == assetId && $0.archivedAt == nil }
            .sorted { $0.startsAt < $1.startsAt }
    }

    public func get(_ slotId: UUID) async throws -> Slot {
        guard let s = slots.first(where: { $0.id == slotId && $0.archivedAt == nil }) else {
            throw SlotError.notFound
        }
        return s
    }

    /// Test helper: install a snapshot so view code can render without
    /// going through the wizard / lifecycle RPCs.
    public func stub(_ slot: Slot) {
        slots.append(slot)
    }
}

// MARK: - Live

public actor LiveSlotRepository: SlotRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func listForGroup(_ groupId: UUID) async throws -> [Slot] {
        do {
            let rows: [ResourceRow] = try await client
                .from("resources")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .eq("resource_type", value: "slot")
                .is("archived_at", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
            return try rows.map { try $0.decodeAsSlot() }.sorted { $0.startsAt < $1.startsAt }
        } catch let e as SlotError {
            throw e
        } catch let e as ResourceRowError {
            throw SlotError.decodeFailed("\(e)")
        } catch {
            throw SlotError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForAsset(_ assetId: UUID) async throws -> [Slot] {
        do {
            // Postgrest's jsonb metadata can be filtered via `metadata->>asset_id`.
            // The current PostgREST API exposes this through `.eq("metadata->>asset_id", ...)`.
            let rows: [ResourceRow] = try await client
                .from("resources")
                .select()
                .eq("resource_type", value: "slot")
                .eq("metadata->>asset_id", value: assetId.uuidString.lowercased())
                .is("archived_at", value: nil)
                .execute()
                .value
            return try rows.map { try $0.decodeAsSlot() }.sorted { $0.startsAt < $1.startsAt }
        } catch let e as ResourceRowError {
            throw SlotError.decodeFailed("\(e)")
        } catch {
            throw SlotError.rpcFailed(error.localizedDescription)
        }
    }

    public func get(_ slotId: UUID) async throws -> Slot {
        do {
            let row: ResourceRow = try await client
                .from("resources")
                .select()
                .eq("id", value: slotId.uuidString.lowercased())
                .eq("resource_type", value: "slot")
                .single()
                .execute()
                .value
            return try row.decodeAsSlot()
        } catch let e as ResourceRowError {
            throw SlotError.decodeFailed("\(e)")
        } catch {
            throw SlotError.rpcFailed(error.localizedDescription)
        }
    }
}
