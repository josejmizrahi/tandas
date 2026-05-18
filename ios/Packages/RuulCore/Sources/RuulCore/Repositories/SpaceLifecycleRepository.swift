import Foundation
import Supabase

/// Write-path for the canonical space spec lifecycle (mig 00266).
///
/// Wraps the 9 SECURITY DEFINER RPCs that materialize space atoms:
///   - book_space           — claim entire space for a window
///   - cancel_booking       — booker / admin teardown
///   - expire_booking       — service_role / cron only (not exposed here)
///   - join_waitlist        — append to ordered queue
///   - promote_space_from_waitlist — admin / service_role promote top
///   - check_in_to_space    — record arrival
///   - grant_space_access   — admin override (bypass booking gate)
///   - revoke_space_access  — terminate prior grant
///   - update_space_metadata — admin patch (name / capacity / location / desc)
///
/// Reads (availability, occupancy, capacity, history) flow through
/// `SpaceRepository` + the projection views shipped in mig 00267.
///
/// Doctrine: bookings are atoms (Plans/Active/Space.md §8). The `bookings`
/// table is the truth — the booking id returned by `bookSpace` is the
/// stable identifier for the lifetime of the claim. Cancellation /
/// expiration record additional atoms; the projection joins them.
public protocol SpaceLifecycleRepository: Actor {
    /// Claims the entire space for a window. Returns the booking id.
    /// Rejects with `.capacityReached` when active bookings >= capacity —
    /// caller routes to `joinWaitlist`.
    func bookSpace(
        space spaceId: UUID,
        startsAt: Date?,
        endsAt: Date?,
        notes: String?
    ) async throws -> UUID

    /// Cancels an existing booking. Caller must be the original booker
    /// or a group admin. Idempotent — no-op if already cancelled/expired.
    func cancelBooking(booking bookingId: UUID, reason: String?) async throws

    /// Appends the caller to the ordered waitlist. Idempotent — returns
    /// the existing atom id if the caller already holds an active queue row.
    func joinWaitlist(
        space spaceId: UUID,
        priority: Int,
        notes: String?
    ) async throws -> UUID

    /// Promotes the top of the waitlist. Admin only on the iOS surface;
    /// service_role (cron) also calls this server-side after a free.
    /// Returns the promotion atom id, or `nil` if the queue is empty.
    func promoteFromWaitlist(space spaceId: UUID) async throws -> UUID?

    /// Records caller's arrival. Booking id is optional — pure walk-ins
    /// can check in without a prior booking (rule engine decides whether
    /// that's allowed via consequences).
    func checkInToSpace(
        space spaceId: UUID,
        booking bookingId: UUID?,
        notes: String?
    ) async throws -> UUID

    /// Admin override granting a member access outside the booking flow.
    /// Optional `until` creates a time-boxed grant.
    func grantSpaceAccess(
        space spaceId: UUID,
        to memberId: UUID,
        until: Date?,
        reason: String?
    ) async throws

    /// Admin terminates a previously-granted access. No-op if no active
    /// grant exists for the member (the atom still fires for audit).
    func revokeSpaceAccess(
        space spaceId: UUID,
        member memberId: UUID,
        reason: String?
    ) async throws

    /// Patches the space metadata (name / capacity / location_name /
    /// location_lat / location_lng / description). Admin only.
    func updateSpaceMetadata(
        space spaceId: UUID,
        patch: JSONConfig
    ) async throws
}

public enum SpaceLifecycleError: LocalizedError, Sendable, Equatable {
    case permissionDenied(String)
    case notFound(String)
    case invalidState(String)
    case capacityReached(active: Int, capacity: Int)
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let m): return "Permiso denegado: \(m)"
        case .notFound(let m):         return "No encontrado: \(m)"
        case .invalidState(let m):     return "Estado inválido: \(m)"
        case .capacityReached(let a, let c): return "Aforo lleno: \(a)/\(c). Únete a la lista de espera."
        case .rpcFailed(let m):        return "Error: \(m)"
        }
    }
}

// MARK: - Mock

public actor MockSpaceLifecycleRepository: SpaceLifecycleRepository {
    public private(set) var bookings: [(spaceId: UUID, bookingId: UUID, startsAt: Date?, endsAt: Date?)] = []
    public private(set) var cancellations: [UUID] = []
    public private(set) var waitlistJoins: [UUID] = []
    public private(set) var waitlistPromotions: [UUID] = []
    public private(set) var checkIns: [(UUID, UUID?)] = []
    public private(set) var accessGrants: [(UUID, UUID, Date?)] = []
    public private(set) var accessRevokes: [(UUID, UUID)] = []
    public private(set) var metadataPatches: [(UUID, JSONConfig)] = []

    /// Optional throw — install before invoking to simulate server errors.
    public var nextError: SpaceLifecycleError?
    /// Capacity to simulate on `bookSpace`. nil = unlimited.
    public var simulatedCapacity: Int?

    public init() {}

    public func bookSpace(
        space spaceId: UUID, startsAt: Date?, endsAt: Date?, notes: String?
    ) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        if let cap = simulatedCapacity {
            let active = bookings.filter { $0.spaceId == spaceId && !cancellations.contains($0.bookingId) }.count
            if active >= cap {
                throw SpaceLifecycleError.capacityReached(active: active, capacity: cap)
            }
        }
        let id = UUID()
        bookings.append((spaceId, id, startsAt, endsAt))
        return id
    }

    public func cancelBooking(booking bookingId: UUID, reason: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        cancellations.append(bookingId)
    }

    public func joinWaitlist(space spaceId: UUID, priority: Int, notes: String?) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        waitlistJoins.append(spaceId)
        return UUID()
    }

    public func promoteFromWaitlist(space spaceId: UUID) async throws -> UUID? {
        if let err = nextError { nextError = nil; throw err }
        waitlistPromotions.append(spaceId)
        return UUID()
    }

    public func checkInToSpace(
        space spaceId: UUID, booking bookingId: UUID?, notes: String?
    ) async throws -> UUID {
        if let err = nextError { nextError = nil; throw err }
        checkIns.append((spaceId, bookingId))
        return UUID()
    }

    public func grantSpaceAccess(
        space spaceId: UUID, to memberId: UUID, until: Date?, reason: String?
    ) async throws {
        if let err = nextError { nextError = nil; throw err }
        accessGrants.append((spaceId, memberId, until))
    }

    public func revokeSpaceAccess(
        space spaceId: UUID, member memberId: UUID, reason: String?
    ) async throws {
        if let err = nextError { nextError = nil; throw err }
        accessRevokes.append((spaceId, memberId))
    }

    public func updateSpaceMetadata(space spaceId: UUID, patch: JSONConfig) async throws {
        if let err = nextError { nextError = nil; throw err }
        metadataPatches.append((spaceId, patch))
    }
}

// MARK: - Live

public actor LiveSpaceLifecycleRepository: SpaceLifecycleRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Maps a thrown supabase error into the typed enum. Pattern-matches the
    /// known server-side error messages (codes 23514 for capacity, 42501 for
    /// auth/permission, 02000 for not_found, 22023 for invalid state).
    private func map(_ error: Error) -> SpaceLifecycleError {
        let m = error.localizedDescription
        let lower = m.lowercased()
        if lower.contains("at capacity") {
            // Try to pluck the counts; fallback to generic.
            return .capacityReached(active: 0, capacity: 0)
        }
        if lower.contains("permission denied") || lower.contains("admin only")
            || lower.contains("not authenticated") || lower.contains("only the booker") {
            return .permissionDenied(m)
        }
        if lower.contains("not found") || lower.contains("not a member") {
            return .notFound(m)
        }
        if lower.contains("must be") || lower.contains("cannot be") || lower.contains("not active") {
            return .invalidState(m)
        }
        return .rpcFailed(m)
    }

    public func bookSpace(
        space spaceId: UUID, startsAt: Date?, endsAt: Date?, notes: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_space_id: String
            let p_starts_at: String?
            let p_ends_at: String?
            let p_notes: String?
        }
        do {
            let resp = try await client
                .rpc("book_space", params: Params(
                    p_space_id: spaceId.uuidString.lowercased(),
                    p_starts_at: startsAt.map(isoString),
                    p_ends_at: endsAt.map(isoString),
                    p_notes: (notes?.isEmpty ?? true) ? nil : notes
                ))
                .execute()
            let raw = String(decoding: resp.data, as: UTF8.self)
                .trimmingCharacters(in: .init(charactersIn: "\"\n "))
            guard let id = UUID(uuidString: raw) else {
                throw SpaceLifecycleError.rpcFailed("book_space returned non-UUID: \(raw)")
            }
            return id
        } catch let e as SpaceLifecycleError {
            throw e
        } catch {
            throw map(error)
        }
    }

    public func cancelBooking(booking bookingId: UUID, reason: String?) async throws {
        struct Params: Encodable {
            let p_booking_id: String
            let p_reason: String?
        }
        do {
            _ = try await client
                .rpc("cancel_booking", params: Params(
                    p_booking_id: bookingId.uuidString.lowercased(),
                    p_reason: (reason?.isEmpty ?? true) ? nil : reason
                ))
                .execute()
        } catch {
            throw map(error)
        }
    }

    public func joinWaitlist(
        space spaceId: UUID, priority: Int, notes: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_space_id: String
            let p_priority: Int
            let p_notes: String?
        }
        do {
            let resp = try await client
                .rpc("join_waitlist", params: Params(
                    p_space_id: spaceId.uuidString.lowercased(),
                    p_priority: priority,
                    p_notes: (notes?.isEmpty ?? true) ? nil : notes
                ))
                .execute()
            let raw = String(decoding: resp.data, as: UTF8.self)
                .trimmingCharacters(in: .init(charactersIn: "\"\n "))
            guard let id = UUID(uuidString: raw) else {
                throw SpaceLifecycleError.rpcFailed("join_waitlist returned non-UUID: \(raw)")
            }
            return id
        } catch let e as SpaceLifecycleError {
            throw e
        } catch {
            throw map(error)
        }
    }

    public func promoteFromWaitlist(space spaceId: UUID) async throws -> UUID? {
        struct Params: Encodable {
            let p_space_id: String
        }
        do {
            let resp = try await client
                .rpc("promote_space_from_waitlist", params: Params(
                    p_space_id: spaceId.uuidString.lowercased()
                ))
                .execute()
            let raw = String(decoding: resp.data, as: UTF8.self)
                .trimmingCharacters(in: .init(charactersIn: "\"\n "))
            if raw.isEmpty || raw == "null" { return nil }
            guard let id = UUID(uuidString: raw) else { return nil }
            return id
        } catch {
            throw map(error)
        }
    }

    public func checkInToSpace(
        space spaceId: UUID, booking bookingId: UUID?, notes: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_space_id: String
            let p_booking_id: String?
            let p_notes: String?
        }
        do {
            let resp = try await client
                .rpc("check_in_to_space", params: Params(
                    p_space_id: spaceId.uuidString.lowercased(),
                    p_booking_id: bookingId?.uuidString.lowercased(),
                    p_notes: (notes?.isEmpty ?? true) ? nil : notes
                ))
                .execute()
            let raw = String(decoding: resp.data, as: UTF8.self)
                .trimmingCharacters(in: .init(charactersIn: "\"\n "))
            guard let id = UUID(uuidString: raw) else {
                throw SpaceLifecycleError.rpcFailed("check_in_to_space returned non-UUID: \(raw)")
            }
            return id
        } catch let e as SpaceLifecycleError {
            throw e
        } catch {
            throw map(error)
        }
    }

    public func grantSpaceAccess(
        space spaceId: UUID, to memberId: UUID, until: Date?, reason: String?
    ) async throws {
        struct Params: Encodable {
            let p_space_id: String
            let p_member_id: String
            let p_until: String?
            let p_reason: String?
        }
        do {
            _ = try await client
                .rpc("grant_space_access", params: Params(
                    p_space_id: spaceId.uuidString.lowercased(),
                    p_member_id: memberId.uuidString.lowercased(),
                    p_until: until.map(isoString),
                    p_reason: (reason?.isEmpty ?? true) ? nil : reason
                ))
                .execute()
        } catch {
            throw map(error)
        }
    }

    public func revokeSpaceAccess(
        space spaceId: UUID, member memberId: UUID, reason: String?
    ) async throws {
        struct Params: Encodable {
            let p_space_id: String
            let p_member_id: String
            let p_reason: String?
        }
        do {
            _ = try await client
                .rpc("revoke_space_access", params: Params(
                    p_space_id: spaceId.uuidString.lowercased(),
                    p_member_id: memberId.uuidString.lowercased(),
                    p_reason: (reason?.isEmpty ?? true) ? nil : reason
                ))
                .execute()
        } catch {
            throw map(error)
        }
    }

    public func updateSpaceMetadata(
        space spaceId: UUID, patch: JSONConfig
    ) async throws {
        struct Params: Encodable {
            let p_space_id: String
            let p_patch: JSONConfig
        }
        do {
            _ = try await client
                .rpc("update_space_metadata", params: Params(
                    p_space_id: spaceId.uuidString.lowercased(),
                    p_patch: patch
                ))
                .execute()
        } catch {
            throw map(error)
        }
    }
}
