import Foundation
import Supabase

/// Write-path for the canonical `right` resource_type. Wraps the
/// SECURITY DEFINER RPCs introduced by mig 00198 (creation + lifecycle)
/// and mig 00199 (metadata-update + expiration).
///
/// `create_right` is intentionally NOT in this protocol — creation
/// flows through the universal ResourceWizard via
/// `ResourceDraftRepository.build(_:)` (mig 00198 `right` branch),
/// matching the Fund / Asset shape. This protocol owns the
/// **post-create** lifecycle surface only.
///
/// Each RPC is gated server-side: caller must be an active member of
/// the right's group; transferable/delegable flags enforce the relevant
/// permission per call. UI must surface ResultErrors and not assume
/// the RPC will succeed.
public protocol RightRepository: Actor {
    /// Reassigns a transferable right to a new holder. Both holder and
    /// transferee must be active members of the right's group.
    /// Server enforces `metadata.transferable = true`. Emits
    /// `rightTransferred` system_event.
    func transfer(_ rightId: UUID, to memberId: UUID, reason: String?) async throws

    /// Records a temporary delegation. Holder unchanged; delegate
    /// stored in `metadata.delegate_member_id` with optional
    /// `metadata.delegate_until`. Server enforces
    /// `metadata.delegable = true`. Emits `rightDelegated`.
    func delegate(_ rightId: UUID, to memberId: UUID, until: Date?, reason: String?) async throws

    /// Soft revoke — flips `status = revoked`. Emits `rightRevoked`.
    /// Idempotent. Row stays in `resources`; projections filter by
    /// status.
    func revoke(_ rightId: UUID, reason: String?) async throws

    /// Records a temporary suspension via `metadata.suspended_until`.
    /// Status stays active so `restore_right` can be a clean recovery.
    /// Emits `rightSuspended`.
    func suspend(_ rightId: UUID, until: Date?, reason: String?) async throws

    /// Clears a suspension AND lifts revocation back to active. Emits
    /// `rightRestored`. Pair with suspend / revoke.
    func restore(_ rightId: UUID, reason: String?) async throws

    /// Records that the holder (or active delegate) used the right —
    /// booked the palco, voted with their equity, accessed the asset.
    /// Updates `metadata.last_exercised_at`; emits `rightExercised`.
    func exercise(_ rightId: UUID, context: JSONConfig) async throws

    /// Tunes the right's non-lifecycle knobs (priority, exclusive,
    /// transferable, delegable, divisible, expires_at, source,
    /// target_resource_id, target_capability, scope, name). Server
    /// rejects keys that belong to dedicated lifecycle RPCs (holder,
    /// delegate, status, suspended_*). Mig 00199.
    func updateMetadata(_ rightId: UUID, patch: JSONConfig) async throws
}

/// Domain errors surfaced from the right-lifecycle RPCs. Mirrors the
/// SQLSTATE codes the migrations use so UI can branch on the failure
/// mode (e.g. show "not transferable" vs. "not authorised").
public enum RightError: LocalizedError, Sendable {
    case notAuthenticated
    case notAuthorized(String)
    case notFound(String)
    case invalidState(String)
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "Necesitas iniciar sesión."
        case .notAuthorized(let m):    return "Permiso denegado: \(m)"
        case .notFound(let m):         return "No encontrado: \(m)"
        case .invalidState(let m):     return "Estado inválido: \(m)"
        case .rpcFailed(let m):        return "Error: \(m)"
        }
    }
}

// MARK: - Mock

public actor MockRightRepository: RightRepository {
    public private(set) var transfers: [(UUID, UUID, String?)] = []
    public private(set) var delegations: [(UUID, UUID, Date?, String?)] = []
    public private(set) var revokes: [(UUID, String?)] = []
    public private(set) var suspensions: [(UUID, Date?, String?)] = []
    public private(set) var restorations: [(UUID, String?)] = []
    public private(set) var exercises: [(UUID, JSONConfig)] = []
    public private(set) var metadataUpdates: [(UUID, JSONConfig)] = []

    public var nextError: RightError?

    public init() {}

    public func transfer(_ rightId: UUID, to memberId: UUID, reason: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        transfers.append((rightId, memberId, reason))
    }

    public func delegate(_ rightId: UUID, to memberId: UUID, until: Date?, reason: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        delegations.append((rightId, memberId, until, reason))
    }

    public func revoke(_ rightId: UUID, reason: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        revokes.append((rightId, reason))
    }

    public func suspend(_ rightId: UUID, until: Date?, reason: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        suspensions.append((rightId, until, reason))
    }

    public func restore(_ rightId: UUID, reason: String?) async throws {
        if let err = nextError { nextError = nil; throw err }
        restorations.append((rightId, reason))
    }

    public func exercise(_ rightId: UUID, context: JSONConfig) async throws {
        if let err = nextError { nextError = nil; throw err }
        exercises.append((rightId, context))
    }

    public func updateMetadata(_ rightId: UUID, patch: JSONConfig) async throws {
        if let err = nextError { nextError = nil; throw err }
        metadataUpdates.append((rightId, patch))
    }
}

// MARK: - Live

public actor LiveRightRepository: RightRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    /// ISO8601 with fractional seconds. Built per-call to dodge the
    /// non-Sendable static-formatter under Swift 6 strict concurrency
    /// (same pattern as LiveSlotLifecycleRepository).
    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public func transfer(_ rightId: UUID, to memberId: UUID, reason: String?) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_to_member_id: String
            let p_reason: String?
        }
        do {
            try await client
                .rpc("transfer_right", params: Params(
                    p_right_id:     rightId.uuidString.lowercased(),
                    p_to_member_id: memberId.uuidString.lowercased(),
                    p_reason:       reason
                ))
                .execute()
        } catch {
            throw mapError(error, default: "transfer_right failed")
        }
    }

    public func delegate(_ rightId: UUID, to memberId: UUID, until: Date?, reason: String?) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_delegate_member_id: String
            let p_until: String?
            let p_reason: String?
        }
        do {
            try await client
                .rpc("delegate_right", params: Params(
                    p_right_id:           rightId.uuidString.lowercased(),
                    p_delegate_member_id: memberId.uuidString.lowercased(),
                    p_until:              until.map(isoString),
                    p_reason:             reason
                ))
                .execute()
        } catch {
            throw mapError(error, default: "delegate_right failed")
        }
    }

    public func revoke(_ rightId: UUID, reason: String?) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_reason: String?
        }
        do {
            try await client
                .rpc("revoke_right", params: Params(
                    p_right_id: rightId.uuidString.lowercased(),
                    p_reason:   reason
                ))
                .execute()
        } catch {
            throw mapError(error, default: "revoke_right failed")
        }
    }

    public func suspend(_ rightId: UUID, until: Date?, reason: String?) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_until: String?
            let p_reason: String?
        }
        do {
            try await client
                .rpc("suspend_right", params: Params(
                    p_right_id: rightId.uuidString.lowercased(),
                    p_until:    until.map(isoString),
                    p_reason:   reason
                ))
                .execute()
        } catch {
            throw mapError(error, default: "suspend_right failed")
        }
    }

    public func restore(_ rightId: UUID, reason: String?) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_reason: String?
        }
        do {
            try await client
                .rpc("restore_right", params: Params(
                    p_right_id: rightId.uuidString.lowercased(),
                    p_reason:   reason
                ))
                .execute()
        } catch {
            throw mapError(error, default: "restore_right failed")
        }
    }

    public func exercise(_ rightId: UUID, context: JSONConfig) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_context: JSONConfig
        }
        do {
            try await client
                .rpc("exercise_right", params: Params(
                    p_right_id: rightId.uuidString.lowercased(),
                    p_context:  context
                ))
                .execute()
        } catch {
            throw mapError(error, default: "exercise_right failed")
        }
    }

    public func updateMetadata(_ rightId: UUID, patch: JSONConfig) async throws {
        struct Params: Encodable {
            let p_right_id: String
            let p_patch: JSONConfig
        }
        do {
            try await client
                .rpc("update_right_metadata", params: Params(
                    p_right_id: rightId.uuidString.lowercased(),
                    p_patch:    patch
                ))
                .execute()
        } catch {
            throw mapError(error, default: "update_right_metadata failed")
        }
    }

    private func mapError(_ error: Error, default defaultMsg: String) -> RightError {
        let msg = (error as NSError).localizedDescription.lowercased()
        if msg.contains("not authenticated") { return .notAuthenticated }
        if msg.contains("not a member")
            || msg.contains("not transferable")
            || msg.contains("not delegable")
            || msg.contains("neither holder nor")
            || msg.contains("cannot be updated")
            || msg.contains("permission denied") { return .notAuthorized(msg) }
        if msg.contains("not found") || msg.contains("archived") { return .notFound(msg) }
        if msg.contains("must be")
            || msg.contains("invalid scope")
            || msg.contains("non-negative")
            || msg.contains("required")
            || msg.contains("non-empty") { return .invalidState(msg) }
        return .rpcFailed("\(defaultMsg): \(msg)")
    }
}
