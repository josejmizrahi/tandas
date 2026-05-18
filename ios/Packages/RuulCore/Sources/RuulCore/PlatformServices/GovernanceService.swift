import Foundation
import OSLog
import Supabase

/// Abstraction over `GovernanceService` so coordinators can inject mocks in
/// tests. The single requirement mirrors the actor's `canPerform` signature.
/// Marked `async throws` so callers must `await` (actor isolation) and so
/// future implementations that consult I/O can fail without breaking the
/// protocol surface; the current `GovernanceService` actor never throws.
public protocol GovernanceServiceProtocol: Sendable {
    func canPerform(
        _ action: GovernanceAction,
        member: Member,
        in group: Group,
        context: GovernanceContext?
    ) async throws -> GovernanceDecision

    /// Role-based permission check (RolesV2 foundation slice — Gap 3).
    /// Consults `group.roles[member.role].permissions`. Independent of
    /// `canPerform` (governance jsonb) — the two compose: an action may
    /// be allowed via either the role permission OR the governance
    /// `whoCan*` level. Phase 5 will rewire the RLS layer to delegate
    /// to `has_permission()` (mig 00063); for now this is consultative
    /// only and callers decide how to combine.
    ///
    /// Default implementation reads from `group.roles` locally — no I/O.
    /// Fallback to `RoleDefinition.v1SystemRoles` if the row predates
    /// mig 00063 (test fixtures, offline path).
    func hasPermission(
        _ permission: Permission,
        member: Member,
        in group: Group
    ) async throws -> Bool
}

public extension GovernanceServiceProtocol {
    func hasPermission(
        _ permission: Permission,
        member: Member,
        in group: Group
    ) async throws -> Bool {
        // V24.2 (mig 00303): rawRoles is the only source — legacy `role`
        // text fallback removed with the column drop.
        // Post-mig-00262 + 00290, 'admin' has its own catalog entry and
        // every founder is also explicitly an admin. No alias needed.
        guard !member.rawRoles.isEmpty else { return false }
        let catalog = group.effectiveRoles
        for rawRoleId in member.rawRoles {
            if let def = catalog[rawRoleId], def.grants(permission) {
                return true
            }
        }
        return false
    }
}

/// Single point of decision for "can member X perform action Y in group Z?".
/// Reads `Group.governance` and `Member.roles`; defers vote-required actions
/// to the caller (vote creation isn't done by this service — it just signals
/// that a vote is required).
///
/// V1 evaluators:
///   - `.founder`           → only members with `MemberRole.founder`
///   - `.anyMember`         → any active member
///   - `.host`              → only the host of the contextual event (caller
///                             must pass the resource so we can look up host)
///   - `.majorityVote`      → returns `.requiresVote` (caller opens vote
///                             via VoteService)
///   - `.supermajorityVote` → same as above with higher threshold
///   - `.treasurer`         → V2 (returns `.denied` until role is wired)
///
/// Stateless: every call is pure. Marked actor for futureproofing in case
/// it grows DB consultations (active votes, member counts, etc.); current
/// implementation does no I/O.
public actor GovernanceService: GovernanceServiceProtocol {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "governance")

    /// When non-nil, `hasPermission` consults the server's `has_permission`
    /// RPC (mig 00228) with a short TTL cache. When nil (tests / mocks /
    /// pure-local previews), falls back to the protocol default impl which
    /// walks `group.roles` locally — same semantics, no I/O.
    private let client: SupabaseClient?

    /// Cache key for the server-RPC hasPermission cache.
    private struct PermissionCacheKey: Hashable {
        let groupId: UUID
        let userId: UUID
        let permission: String
    }

    /// (group, user, permission) → (result, timestamp). 30s TTL — server
    /// is authoritative on actions, so a brief UI gating drift is bounded
    /// (worst case: stale cache shows/hides a control; the RPC re-validates).
    private var permissionCache: [PermissionCacheKey: (result: Bool, at: Date)] = [:]
    private static let permissionCacheTTL: TimeInterval = 30

    public init(client: SupabaseClient? = nil) {
        self.client = client
    }

    // MARK: - hasPermission server override
    //
    // Sprint E (V17 fix): override the protocol-extension default impl
    // to consult the server's has_permission RPC (mig 00228) when wired
    // with a SupabaseClient. Sub-30s TTL cache prevents N+1 round-trips
    // for repeated UI gating reads in the same render cycle.
    //
    // No explicit invalidation hooks today: 30s TTL is short enough that
    // role mutations (assign/unassign/upsert/delete role RPCs) become
    // visible within one refresh. The server remains the authoritative
    // gate for actions — a stale cache only mis-renders, never escalates.
    public func hasPermission(
        _ permission: Permission,
        member: Member,
        in group: Group
    ) async throws -> Bool {
        guard let client else {
            return localHasPermission(permission, member: member, in: group)
        }

        let permString = permission.rawString
        let key = PermissionCacheKey(
            groupId: group.id,
            userId: member.userId,
            permission: permString
        )

        if let cached = permissionCache[key],
           Date().timeIntervalSince(cached.at) < Self.permissionCacheTTL {
            return cached.result
        }

        struct RpcParams: Encodable {
            let p_group_id:   String
            let p_user_id:    String
            let p_permission: String
        }
        let result: Bool = try await client
            .rpc("has_permission", params: RpcParams(
                p_group_id:   group.id.uuidString.lowercased(),
                p_user_id:    member.userId.uuidString.lowercased(),
                p_permission: permString
            ))
            .execute()
            .value

        permissionCache[key] = (result, Date())
        return result
    }

    /// Local fallback used when no Supabase client is wired (tests / mocks).
    /// Same semantics as the protocol default impl. Inlined here to keep
    /// the actor self-contained.
    private nonisolated func localHasPermission(
        _ permission: Permission,
        member: Member,
        in group: Group
    ) -> Bool {
        // V24.2 (mig 00303): rawRoles is the only source.
        guard !member.rawRoles.isEmpty else { return false }
        let catalog = group.effectiveRoles
        for rawRoleId in member.rawRoles {
            if let def = catalog[rawRoleId], def.grants(permission) {
                return true
            }
        }
        return false
    }

    /// Manually invalidate the cache. Callers that just mutated roles
    /// (assignRole, unassignRole, upsert/delete role catalog) can call
    /// this to force a fresh server read on the next hasPermission.
    public func clearPermissionCache() {
        permissionCache.removeAll()
    }

    /// Scope-limited cache invalidation: drop entries for one group.
    public func clearPermissionCache(groupId: UUID) {
        permissionCache = permissionCache.filter { $0.key.groupId != groupId }
    }

    /// Decides whether `member` can perform `action` in `group`.
    ///
    /// `context` is optional. For action `.closeEvents`, pass
    /// `.event(hostId: …)` so the `.host` permission level can be evaluated.
    /// For permission levels that require voting, returns `.requiresVote`.
    public func canPerform(
        _ action: GovernanceAction,
        member: Member,
        in group: Group,
        context: GovernanceContext? = nil
    ) -> GovernanceDecision {
        let level = group.effectiveGovernance.level(for: action)
        let decision = evaluate(level: level, member: member, in: group, context: context)
        log.debug("canPerform action=\(action.rawValue, privacy: .public) level=\(level.rawString, privacy: .public) decision=\(String(describing: decision), privacy: .public)")
        return decision
    }

    /// Convenience boolean for callers that don't care about the
    /// `.requiresVote` distinction. Treats `.requiresVote` as "no" because
    /// the action isn't immediately permitted.
    public func isAllowed(
        _ action: GovernanceAction,
        member: Member,
        in group: Group,
        context: GovernanceContext? = nil
    ) -> Bool {
        if case .allowed = canPerform(action, member: member, in: group, context: context) {
            return true
        }
        return false
    }

    // MARK: - Internal evaluation

    private func evaluate(
        level: PermissionLevel,
        member: Member,
        in group: Group,
        context: GovernanceContext?
    ) -> GovernanceDecision {
        switch level {
        case .founder:
            return member.isFounder ? .allowed : .denied(reason: .notFounder)

        case .anyMember:
            return member.active ? .allowed : .denied(reason: .inactiveMember)

        case .host:
            guard case .event(let hostId) = context else {
                return .denied(reason: .missingContext("event hostId required"))
            }
            return member.userId == hostId ? .allowed : .denied(reason: .notHost)

        case .majorityVote:
            return .requiresVote(quorumPercent: group.effectiveGovernance.votingQuorumPercent,
                                 thresholdPercent: group.effectiveGovernance.votingThresholdPercent)

        case .supermajorityVote:
            return .requiresVote(quorumPercent: group.effectiveGovernance.votingQuorumPercent,
                                 thresholdPercent: 66)

        case .treasurer:
            // V2 — treasurer role exists in MemberRole but no UI assigns it
            // yet. Deny by default.
            return member.roles.contains(.treasurer) ? .allowed : .denied(reason: .notTreasurer)

        case .unknown(let raw):
            // Forward-compat: a future permission level was persisted that
            // this client doesn't understand. Deny safely.
            return .denied(reason: .unknownLevel(raw))
        }
    }
}

/// Context the service needs for action-level evaluators that depend on the
/// resource being acted on. Pass `.event(hostId:)` when checking
/// `.closeEvents`.
public enum GovernanceContext: Sendable, Hashable {
    case event(hostId: UUID)
    case rule(ruleId: UUID)
    case fund(fundId: UUID)
    case slot(slotId: UUID)
}

/// Result of a `canPerform` check.
public enum GovernanceDecision: Sendable, Hashable {
    /// Member is allowed to perform the action immediately.
    case allowed

    /// Action is gated behind a successful vote. Caller is expected to
    /// open one via `VoteService.startVote(...)` and act on resolution.
    case requiresVote(quorumPercent: Int, thresholdPercent: Int)

    /// Member is not allowed.
    case denied(reason: DeniedReason)

    public enum DeniedReason: Sendable, Hashable {
        case notFounder
        case notHost
        case notTreasurer
        case inactiveMember
        case missingContext(String)
        case unknownLevel(String)
    }
}
