import Foundation
import Supabase

public enum SpaceProjectionError: Error, Equatable {
    case rpcFailed(String)
    case notFound
}

/// Read-only surface for the 4 canonical space projection views
/// (mig 00267 — Plans/Active/Space.md §10).
///
/// Each method maps to one view and filters by `space_id`. Reads use
/// `security_invoker = on` views so RLS on the base tables
/// (`system_events`, `bookings`, `check_in_actions`, `resources`)
/// gates the result set — no extra policies needed at this layer.
///
/// Writes do NOT exist here; mutations flow through
/// `SpaceLifecycleRepository` (mig 00266 RPCs) which append atoms
/// the views then derive.
public protocol SpaceProjectionRepository: Actor {
    /// Active (non-cancelled, non-expired) bookings for a space.
    func availability(for spaceId: UUID) async throws -> [SpaceAvailabilityRow]

    /// Capacity snapshot for a single space. Returns nil if the space
    /// has no row in the view (archived or non-space resource).
    func capacity(for spaceId: UUID) async throws -> SpaceCapacityRow?

    /// Members currently "inside" a space (latest check-in per member).
    func occupancy(for spaceId: UUID) async throws -> [SpaceOccupancyRow]

    /// Chronological event feed for the space activity tab. Newest
    /// first; capped at `limit` (default 100).
    func history(for spaceId: UUID, limit: Int) async throws -> [SpaceHistoryRow]
}

// MARK: - Mock

public actor MockSpaceProjectionRepository: SpaceProjectionRepository {
    public var availabilityStubs: [UUID: [SpaceAvailabilityRow]] = [:]
    public var capacityStubs: [UUID: SpaceCapacityRow] = [:]
    public var occupancyStubs: [UUID: [SpaceOccupancyRow]] = [:]
    public var historyStubs: [UUID: [SpaceHistoryRow]] = [:]

    public init() {}

    public func availability(for spaceId: UUID) async throws -> [SpaceAvailabilityRow] {
        availabilityStubs[spaceId] ?? []
    }
    public func capacity(for spaceId: UUID) async throws -> SpaceCapacityRow? {
        capacityStubs[spaceId]
    }
    public func occupancy(for spaceId: UUID) async throws -> [SpaceOccupancyRow] {
        occupancyStubs[spaceId] ?? []
    }
    public func history(for spaceId: UUID, limit: Int = 100) async throws -> [SpaceHistoryRow] {
        Array((historyStubs[spaceId] ?? []).prefix(limit))
    }

    public func stub(availability rows: [SpaceAvailabilityRow], for spaceId: UUID) {
        availabilityStubs[spaceId] = rows
    }
    public func stub(capacity row: SpaceCapacityRow, for spaceId: UUID) {
        capacityStubs[spaceId] = row
    }
    public func stub(occupancy rows: [SpaceOccupancyRow], for spaceId: UUID) {
        occupancyStubs[spaceId] = rows
    }
    public func stub(history rows: [SpaceHistoryRow], for spaceId: UUID) {
        historyStubs[spaceId] = rows
    }
}

// MARK: - Live

public actor LiveSpaceProjectionRepository: SpaceProjectionRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func availability(for spaceId: UUID) async throws -> [SpaceAvailabilityRow] {
        do {
            return try await client
                .from("space_availability_view")
                .select()
                .eq("space_id", value: spaceId.uuidString.lowercased())
                .order("starts_at", ascending: true)
                .execute()
                .value
        } catch {
            throw SpaceProjectionError.rpcFailed(error.localizedDescription)
        }
    }

    public func capacity(for spaceId: UUID) async throws -> SpaceCapacityRow? {
        do {
            let rows: [SpaceCapacityRow] = try await client
                .from("space_capacity_view")
                .select()
                .eq("space_id", value: spaceId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            throw SpaceProjectionError.rpcFailed(error.localizedDescription)
        }
    }

    public func occupancy(for spaceId: UUID) async throws -> [SpaceOccupancyRow] {
        do {
            return try await client
                .from("space_occupancy_view")
                .select()
                .eq("space_id", value: spaceId.uuidString.lowercased())
                .order("checked_in_at", ascending: false)
                .execute()
                .value
        } catch {
            throw SpaceProjectionError.rpcFailed(error.localizedDescription)
        }
    }

    public func history(for spaceId: UUID, limit: Int = 100) async throws -> [SpaceHistoryRow] {
        do {
            return try await client
                .from("space_history_view")
                .select()
                .eq("space_id", value: spaceId.uuidString.lowercased())
                .order("occurred_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw SpaceProjectionError.rpcFailed(error.localizedDescription)
        }
    }
}
