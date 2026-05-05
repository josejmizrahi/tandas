import Foundation
import OSLog

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
public actor GovernanceService {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "governance")

    public init() {}

    /// Decides whether `member` can perform `action` in `group`.
    ///
    /// `context` is optional. For action `.closeEvents`, pass
    /// `.event(hostId: …)` so the `.host` permission level can be evaluated.
    /// For permission levels that require voting, returns `.requiresVote`.
    func canPerform(
        _ action: GovernanceAction,
        member: Member,
        in group: Group,
        context: GovernanceContext? = nil
    ) -> GovernanceDecision {
        let level = group.effectiveGovernance.level(for: action)
        let decision = evaluate(level: level, member: member, in: group, context: context)
        log.debug("canPerform action=\(action.rawValue, privacy: .public) level=\(level.rawValue, privacy: .public) decision=\(String(describing: decision), privacy: .public)")
        return decision
    }

    /// Convenience boolean for callers that don't care about the
    /// `.requiresVote` distinction. Treats `.requiresVote` as "no" because
    /// the action isn't immediately permitted.
    func isAllowed(
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
    }
}
