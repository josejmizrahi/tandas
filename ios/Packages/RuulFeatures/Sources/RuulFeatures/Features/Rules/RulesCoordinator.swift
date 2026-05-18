import Foundation
import OSLog
import RuulUI
import RuulCore

/// Read-only rules coordinator. Loads the active group's rules and runs a
/// fail-closed governance check so the host view can show or hide the
/// pencil entry to `EditRulesView`. The check mirrors
/// `EditRulesCoordinator.refresh`: only `.allowed` flips `canEditRules`
/// true; any `.requiresVote` / `.denied` / thrown error keeps it false.
@Observable @MainActor
public final class RulesCoordinator {
    public private(set) var rules: [GroupRule] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: CoordinatorError?
    public private(set) var canEditRules: Bool = false
    /// True después de que `refresh()` completó al menos una vez. Permite
    /// distinguir "primera carga" de "loaded empty" cuando `rules == []`.
    /// Consumido por `LoadPhase.fromCollection` en la computed `phase`.
    public private(set) var hasLoaded: Bool = false
    /// Number of votes with `status='open'` for `group`. Refreshed alongside
    /// the rule list so `RulesView` can surface a "Votos abiertos" section
    /// proactively (vs Inbox which only fires when the user has a
    /// `votePending` action). Best-effort: failures keep the previous
    /// value and log; the section just stays hidden when count is 0.
    public private(set) var openVotesCount: Int = 0

    public let group: Group
    /// The current actor's `Member` row in `group`. Used by the governance
    /// check; also reused when constructing an `EditRulesCoordinator` for
    /// the pencil destination.
    public let currentMember: Member
    public let governance: any GovernanceServiceProtocol
    public let ruleRepo: any RuleRepository
    private let voteRepo: any VoteRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rules")

    public init(
        group: Group,
        currentMember: Member,
        governance: any GovernanceServiceProtocol,
        ruleRepo: any RuleRepository,
        voteRepo: any VoteRepository
    ) {
        self.group = group
        self.currentMember = currentMember
        self.governance = governance
        self.ruleRepo = ruleRepo
        self.voteRepo = voteRepo
    }

    /// Adapter para `AsyncContentView`. Deriva el `LoadPhase` desde los
    /// campos `@Observable` que ya mantenemos — el coordinator no necesita
    /// reescribir su lógica.
    public var phase: LoadPhase<[GroupRule]> {
        LoadPhase.fromCollection(
            value: rules,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let decision = try await governance.canPerform(
                .modifyRules,
                member: currentMember,
                in: group,
                context: nil
            )
            if case .allowed = decision {
                canEditRules = true
            } else {
                canEditRules = false
            }
        } catch {
            log.warning("governance check failed: \(error.localizedDescription)")
            canEditRules = false
        }

        do {
            // Server may return both legacy + platform rows for a group seeded
            // before Sprint 1b. Show only platform-shape rows (consequences
            // populated) — those are the ones the engine actually fires.
            let all = try await ruleRepo.list(groupId: group.id)
            let platform = all.filter { !$0.consequences.isEmpty }
            rules = platform.isEmpty ? all : platform
        } catch {
            log.warning("rules load failed: \(error.localizedDescription)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los acuerdos")
        }

        // Best-effort fetch for the "Votos abiertos" surface. Don't surface
        // errors to the user — the section just stays hidden when the count
        // is 0, which is also the failure mode here.
        do {
            let votes = try await voteRepo.openVotes(for: group.id)
            openVotesCount = votes.count
        } catch {
            log.warning("openVotes count load failed: \(error.localizedDescription)")
        }
    }

    public func clearError() { error = nil }
}
