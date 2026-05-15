import Foundation
import Supabase

public enum BookingError: Error, Equatable {
    case rpcFailed(String)
    case notFound
}

/// Read-only surface for `public.bookings` (mig 00216 atom).
///
/// **Writes are not exposed here.** Bookings are append-only atoms; the
/// only write path is `book_slot` (SECURITY DEFINER RPC), which lives
/// on `SlotLifecycleRepository.bookSlot`. Cancellation / expiration
/// land as separate `system_events` rows when those RPCs ship.
///
/// Reads filter the bookings table by group / slot / member. Each row
/// is a single immutable claim — multiple bookings on the same slot are
/// allowed only after a cancel atom retires the prior one (future
/// slice). For V1 the latest row per slot is implicitly the active one.
public protocol BookingRepository: Actor {
    /// All bookings for a group, newest first.
    func listForGroup(_ groupId: UUID, limit: Int) async throws -> [Booking]

    /// Bookings scoped to a single slot, newest first.
    func listForSlot(_ slotId: UUID) async throws -> [Booking]

    /// Bookings made by a single member, newest first.
    func listForMember(_ memberId: UUID, limit: Int) async throws -> [Booking]

    /// Single booking by id.
    func get(_ bookingId: UUID) async throws -> Booking
}

// MARK: - Mock

public actor MockBookingRepository: BookingRepository {
    private var bookings: [Booking]

    public init(seed: [Booking] = []) { self.bookings = seed }

    public func listForGroup(_ groupId: UUID, limit: Int = 200) async throws -> [Booking] {
        bookings
            .filter { $0.groupId == groupId }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    public func listForSlot(_ slotId: UUID) async throws -> [Booking] {
        bookings
            .filter { $0.slotId == slotId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 200) async throws -> [Booking] {
        bookings
            .filter { $0.memberId == memberId }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    public func get(_ bookingId: UUID) async throws -> Booking {
        guard let b = bookings.first(where: { $0.id == bookingId }) else {
            throw BookingError.notFound
        }
        return b
    }

    /// Test helper: append a booking without going through book_slot.
    public func stub(_ booking: Booking) {
        bookings.append(booking)
    }
}

// MARK: - Live

public actor LiveBookingRepository: BookingRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func listForGroup(_ groupId: UUID, limit: Int = 200) async throws -> [Booking] {
        do {
            return try await client
                .from("bookings")
                .select()
                .eq("group_id", value: groupId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw BookingError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForSlot(_ slotId: UUID) async throws -> [Booking] {
        do {
            return try await client
                .from("bookings")
                .select()
                .eq("slot_id", value: slotId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw BookingError.rpcFailed(error.localizedDescription)
        }
    }

    public func listForMember(_ memberId: UUID, limit: Int = 200) async throws -> [Booking] {
        do {
            return try await client
                .from("bookings")
                .select()
                .eq("member_id", value: memberId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            throw BookingError.rpcFailed(error.localizedDescription)
        }
    }

    public func get(_ bookingId: UUID) async throws -> Booking {
        do {
            return try await client
                .from("bookings")
                .select()
                .eq("id", value: bookingId.uuidString.lowercased())
                .single()
                .execute()
                .value
        } catch {
            throw BookingError.rpcFailed(error.localizedDescription)
        }
    }
}
