import Foundation

// MARK: - Governance-aware mutation outcomes (Phase 1)

/// Result of a governance-intercepted rule mutation. Callers branch on
/// this to render the right toast: "Cambio aplicado" vs "Cambio pendiente
/// de votación".
public enum RuleMutationOutcome: Sendable, Hashable {
    /// The change was written directly. Local optimistic state already
    /// matches the new server state.
    case applied
    /// A vote was opened instead. The local optimistic state must be
    /// reverted; the change applies when the vote resolves passed (server
    /// trigger `votes_apply_on_pass_trg`, mig 00089).
    case vote(voteId: UUID)
    /// Caller doesn't have `Permission.modifyRules` and the policy is
    /// `admin_only`. Local state must be reverted; surface "solo admins".
    case adminOnly
}

public enum RuleMutationError: Error, Sendable, Equatable {
    case denied(reason: String)
    case voteOpenFailed(String)
    case underlying(String)
}

/// Domain coordinator that wraps an inner `RuleRepository` and consults
/// `GroupPolicyRepository` before every mutation. When the resolver
/// returns `.voteRequired`, opens a `vote_type = rule_change` carrying a
/// `PendingChangeEnvelope` so the server trigger can auto-apply the diff
/// on resolution=passed. Otherwise delegates to the inner repo.
///
/// **Why this lives in PlatformServices/, not Repositories/:** despite
/// conforming to `RuleRepository` (so the read side is a drop-in for
/// existing callsites), this type is a workflow coordinator — it
/// composes three repos (rules, policies, votes), encodes audit
/// envelopes, opens votes when governance requires them, and returns a
/// typed outcome that drives toast UX. Per
/// Plans/Active/CleanupAudit_2026-05-18 §04.3, the audit flagged this
/// as a service masquerading as a repo. Extracted from
/// `Repositories/RuleRepository.swift` (was 667 LOC, now 444 LOC).
/// Renamed `InterceptingRuleRepository → RuleGovernanceCoordinator` to
/// match what it actually does.
///
/// Compose at the AppState seam: the rest of the codebase keeps talking
/// to `RuleRepository`. The governance-aware mutation methods
/// (`setIsActive(_:isActive:groupId:currentIsActive:)` and the analogous
/// amount one) are NEW surface — call sites adopt them gradually. The
/// non-governance methods (`list`, `listForResource`,
/// `pendingRepealVote`, …) pass through to `inner` untouched, so this
/// actor is also a drop-in `RuleRepository` for the read side.
public actor RuleGovernanceCoordinator: RuleRepository {
    private let inner: any RuleRepository
    private let policyRepo: any GroupPolicyRepository
    private let voteRepo: any VoteRepository
    private let actorUserId: UUID

    public init(
        inner: any RuleRepository,
        policyRepo: any GroupPolicyRepository,
        voteRepo: any VoteRepository,
        actorUserId: UUID
    ) {
        self.inner = inner
        self.policyRepo = policyRepo
        self.voteRepo = voteRepo
        self.actorUserId = actorUserId
    }

    // MARK: Governance-aware mutations

    /// Toggles `is_active` with governance check.
    /// - parameter currentIsActive: the value before the user's tap;
    ///   needed to compose the `before` half of the audit envelope.
    public func setIsActive(
        ruleId: UUID,
        isActive: Bool,
        groupId: UUID,
        currentIsActive: Bool
    ) async throws -> RuleMutationOutcome {
        let decision = try await policyRepo.resolve(
            groupId: groupId,
            actorUserId: actorUserId,
            action: .ruleToggle,
            targetPayload: ["rule_id": ruleId.uuidString.lowercased()]
        )
        switch decision {
        case .allowed:
            try await inner.setIsActive(ruleId: ruleId, isActive: isActive)
            return .applied

        case .voteRequired(let q, let t, _):
            let envelope = PendingChangeEnvelope.ruleToggle(
                targetRuleId: ruleId,
                before: .init(isActive: currentIsActive),
                after:  .init(isActive: isActive)
            )
            let payload: JSONConfig
            do {
                payload = try JSONConfig.encoded(envelope)
            } catch {
                throw RuleMutationError.underlying(error.localizedDescription)
            }
            do {
                let voteId = try await voteRepo.startVote(
                    groupId: groupId,
                    voteType: .ruleChange,
                    referenceId: ruleId,
                    title: isActive ? "Activar acuerdo" : "Desactivar acuerdo",
                    description: nil,
                    payload: payload,
                    isAnonymous: false
                )
                _ = (q, t)  // quorum/threshold are server-driven via the vote row
                return .vote(voteId: voteId)
            } catch {
                throw RuleMutationError.voteOpenFailed(error.localizedDescription)
            }

        case .adminOnly:
            return .adminOnly

        case .denied(let reason):
            throw RuleMutationError.denied(reason: reason)
        }
    }

    /// Updates a flat-fine amount with governance check.
    /// - parameter currentAmount: pre-change value for the audit envelope.
    public func setFlatFineAmount(
        rule: GroupRule,
        amount: Int,
        currentAmount: Int
    ) async throws -> RuleMutationOutcome {
        let decision = try await policyRepo.resolve(
            groupId: rule.groupId,
            actorUserId: actorUserId,
            action: .ruleUpdateAmount,
            targetPayload: ["rule_id": rule.id.uuidString.lowercased()]
        )
        switch decision {
        case .allowed:
            try await inner.setFlatFineAmount(rule: rule, amount: amount)
            return .applied

        case .voteRequired:
            let envelope = PendingChangeEnvelope.ruleUpdateAmount(
                targetRuleId: rule.id,
                before: .init(amount: currentAmount),
                after:  .init(amount: amount)
            )
            let payload: JSONConfig
            do {
                payload = try JSONConfig.encoded(envelope)
            } catch {
                throw RuleMutationError.underlying(error.localizedDescription)
            }
            do {
                let voteId = try await voteRepo.startVote(
                    groupId: rule.groupId,
                    voteType: .ruleChange,
                    referenceId: rule.id,
                    title: "Cambiar monto: \(rule.name)",
                    description: nil,
                    payload: payload,
                    isAnonymous: false
                )
                return .vote(voteId: voteId)
            } catch {
                throw RuleMutationError.voteOpenFailed(error.localizedDescription)
            }

        case .adminOnly:
            return .adminOnly

        case .denied(let reason):
            throw RuleMutationError.denied(reason: reason)
        }
    }

    // MARK: RuleRepository conformance (pass-through)

    public func createInitialRules(groupId: UUID, drafts: [OnboardingRuleDraft]) async throws -> [OnboardingRule] {
        try await inner.createInitialRules(groupId: groupId, drafts: drafts)
    }

    public func seedTemplateRules(templateId: String, groupId: UUID) async throws -> [OnboardingRule] {
        try await inner.seedTemplateRules(templateId: templateId, groupId: groupId)
    }

    public func seedModuleRules(moduleSlug: String, groupId: UUID) async throws -> [OnboardingRule] {
        try await inner.seedModuleRules(moduleSlug: moduleSlug, groupId: groupId)
    }

    public func list(groupId: UUID) async throws -> [GroupRule] {
        try await inner.list(groupId: groupId)
    }

    public func listForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        try await inner.listForResource(resourceId)
    }

    public func listScopedForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        try await inner.listScopedForResource(resourceId)
    }

    public func createResourceRule(
        groupId: UUID,
        resourceId: UUID,
        name: String,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) async throws -> GroupRule {
        try await inner.createResourceRule(
            groupId: groupId, resourceId: resourceId, name: name,
            trigger: trigger, conditions: conditions, consequences: consequences
        )
    }

    /// Bare-conformance pass-through. Governance-aware callers should use
    /// the `setIsActive(ruleId:isActive:groupId:currentIsActive:)` overload
    /// — this one bypasses the resolver and writes directly.
    public func setIsActive(ruleId: UUID, isActive: Bool) async throws {
        try await inner.setIsActive(ruleId: ruleId, isActive: isActive)
    }

    /// Bare-conformance pass-through. Governance-aware callers should use
    /// the `setFlatFineAmount(rule:amount:currentAmount:)` overload.
    public func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        try await inner.setFlatFineAmount(rule: rule, amount: amount)
    }

    public func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        try await inner.pendingRepealVote(ruleId: ruleId, groupId: groupId)
    }
}

/// Backward-compat typealias. Allows existing call sites to keep using
/// `InterceptingRuleRepository` until they migrate to the new name.
/// New code should reference `RuleGovernanceCoordinator` directly.
@available(*, deprecated, renamed: "RuleGovernanceCoordinator", message: "Renamed to RuleGovernanceCoordinator. Lives in PlatformServices/ as it's a domain workflow coordinator, not a repo. Per CleanupAudit_2026-05-18 §04.3.")
public typealias InterceptingRuleRepository = RuleGovernanceCoordinator
