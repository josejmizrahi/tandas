import Foundation
import Supabase

/// Write-path for the Phase 2 shared_resource template lifecycle. Wraps
/// the 5 SECURITY DEFINER RPCs from migration 00070:
///   - create_asset
///   - create_slot
///   - assign_slot
///   - book_slot
///   - request_slot_swap
///
/// Read-path (listing assets/slots/bookings) flows through the existing
/// polymorphic `ResourceRepository.list(types:)`. This protocol owns the
/// state-mutation surface only.
///
/// Each RPC is gated server-side by `has_permission()` (mig 00063); the
/// caller is responsible for not calling these RPCs without surfacing a
/// permission-denied error if the server rejects.
public protocol SlotLifecycleRepository: Actor {
    /// Creates a new asset (palco/cabaña/casa). Returns the new asset id.
    /// Emits `assetCreated` system_event server-side.
    func createAsset(in groupId: UUID, name: String, capacity: Int?) async throws -> UUID

    /// Creates a slot under an asset (status='unassigned'). Returns slot id.
    /// `startsAt < endsAt` enforced server-side.
    func createSlot(asset assetId: UUID, startsAt: Date, endsAt: Date) async throws -> UUID

    /// Assigns a slot to a member. Slot must be in unassigned/assigned state.
    /// Emits `slotAssigned` system_event.
    func assignSlot(_ slotId: UUID, to memberId: UUID) async throws

    /// Books the slot for the calling user. If the slot is assigned to a
    /// different member, server rejects with permission denied.
    /// Returns the new booking resource id. Emits `bookingCreated`.
    func bookSlot(_ slotId: UUID) async throws -> UUID

    /// Opens a vote of type `slot_swap` to transfer the slot from the
    /// caller (current assigned holder) to a target member. Returns the
    /// new vote id. Emits `slotSwapRequested` + `voteOpened`.
    func requestSlotSwap(_ slotId: UUID, to targetMemberId: UUID) async throws -> UUID
}

/// Domain errors surfaced from the RPC layer. Mirrors the SQLSTATE codes
/// the migration uses so UI can branch on the failure mode.
public enum SlotLifecycleError: LocalizedError, Sendable {
    case permissionDenied(String)
    case notFound(String)
    case invalidState(String)
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let m): return "Permiso denegado: \(m)"
        case .notFound(let m):         return "No encontrado: \(m)"
        case .invalidState(let m):     return "Estado inválido: \(m)"
        case .rpcFailed(let m):        return "Error: \(m)"
        }
    }
}

// MARK: - Mock

public actor MockSlotLifecycleRepository: SlotLifecycleRepository {
    public private(set) var createdAssets: [UUID] = []
    public private(set) var createdSlots: [UUID] = []
    public private(set) var assignedSlots: [(UUID, UUID)] = []
    public private(set) var bookings: [UUID] = []
    public private(set) var swapRequests: [(UUID, UUID, UUID)] = []  // slot, target, vote

    public var nextError: SlotLifecycleError?

    public init() {}

    public func createAsset(in groupId: UUID, name: String, capacity: Int?) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        let id = UUID()
        createdAssets.append(id)
        return id
    }

    public func createSlot(asset assetId: UUID, startsAt: Date, endsAt: Date) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        let id = UUID()
        createdSlots.append(id)
        return id
    }

    public func assignSlot(_ slotId: UUID, to memberId: UUID) async throws {
        if let err = nextError { nextError = nil; throw err }
        assignedSlots.append((slotId, memberId))
    }

    public func bookSlot(_ slotId: UUID) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        let id = UUID()
        bookings.append(id)
        return id
    }

    public func requestSlotSwap(_ slotId: UUID, to targetMemberId: UUID) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        let voteId = UUID()
        swapRequests.append((slotId, targetMemberId, voteId))
        return voteId
    }
}

// MARK: - Live

public actor LiveSlotLifecycleRepository: SlotLifecycleRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    /// ISO8601 with fractional seconds. Built per call to avoid the
    /// non-Sendable static-formatter issue under Swift 6 strict concurrency.
    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public func createAsset(in groupId: UUID, name: String, capacity: Int?) async throws -> UUID {
        struct Params: Encodable {
            let p_group_id: String
            let p_name: String
            let p_capacity: Int?
        }
        let params = Params(
            p_group_id: groupId.uuidString.lowercased(),
            p_name: name,
            p_capacity: capacity
        )
        do {
            let id: UUID = try await client.rpc("create_asset", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "create_asset failed")
        }
    }

    public func createSlot(asset assetId: UUID, startsAt: Date, endsAt: Date) async throws -> UUID {
        struct Params: Encodable {
            let p_asset_id: String
            let p_starts_at: String
            let p_ends_at: String
        }
        let params = Params(
            p_asset_id: assetId.uuidString.lowercased(),
            p_starts_at: isoString(startsAt),
            p_ends_at: isoString(endsAt)
        )
        do {
            let id: UUID = try await client.rpc("create_slot", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "create_slot failed")
        }
    }

    public func assignSlot(_ slotId: UUID, to memberId: UUID) async throws {
        struct Params: Encodable {
            let p_slot_id: String
            let p_member_id: String
        }
        let params = Params(
            p_slot_id: slotId.uuidString.lowercased(),
            p_member_id: memberId.uuidString.lowercased()
        )
        do {
            _ = try await client.rpc("assign_slot", params: params).execute()
        } catch {
            throw mapError(error, default: "assign_slot failed")
        }
    }

    public func bookSlot(_ slotId: UUID) async throws -> UUID {
        struct Params: Encodable { let p_slot_id: String }
        let params = Params(p_slot_id: slotId.uuidString.lowercased())
        do {
            let id: UUID = try await client.rpc("book_slot", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "book_slot failed")
        }
    }

    public func requestSlotSwap(_ slotId: UUID, to targetMemberId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_slot_id: String
            let p_target_member_id: String
        }
        let params = Params(
            p_slot_id: slotId.uuidString.lowercased(),
            p_target_member_id: targetMemberId.uuidString.lowercased()
        )
        do {
            let id: UUID = try await client.rpc("request_slot_swap", params: params).execute().value
            return id
        } catch {
            throw mapError(error, default: "request_slot_swap failed")
        }
    }

    private func mapError(_ error: Error, default defaultMsg: String) -> SlotLifecycleError {
        let msg = (error as NSError).localizedDescription
        if msg.contains("permission denied") { return .permissionDenied(msg) }
        if msg.contains("not found")         { return .notFound(msg) }
        if msg.contains("must be before")
            || msg.contains("cannot")
            || msg.contains("not active")
            || msg.contains("nothing to swap")
            || msg.contains("cannot swap with yourself")
            || msg.contains("required")      { return .invalidState(msg) }
        return .rpcFailed("\(defaultMsg): \(msg)")
    }
}
