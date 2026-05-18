import Foundation

/// Factory methods that compose application services from the AppState
/// dependency graph. Extracted from `AppState.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §2.1
/// (god-object split). Stored properties stay on the class declaration
/// because Swift class extensions can't add stored state; methods can.
public extension AppState {

    /// Factory: builds an `InterceptingRuleRepository` for the given user.
    /// Coordinators that mutate rules call this to get a governance-aware
    /// wrapper around the raw `ruleRepo`. The wrapper consults
    /// `resolve_governance` before each write — direct-apply, vote-open,
    /// or denied — without changing the underlying live repo.
    ///
    /// Each call instantiates a fresh actor because `actorUserId` is
    /// pinned at construction; coordinators that outlive a session
    /// switch should rebuild this when `session.user.id` changes.
    func makeInterceptingRuleRepo(userId: UUID) -> InterceptingRuleRepository {
        InterceptingRuleRepository(
            inner: ruleRepo,
            policyRepo: policyRepo,
            voteRepo: voteRepo,
            actorUserId: userId
        )
    }
}
