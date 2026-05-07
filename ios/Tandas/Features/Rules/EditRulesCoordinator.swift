import Foundation
import OSLog

/// Editor-side coordinator for the Reglas tab. Owns:
///
/// - **Governance gate** (`canEditRules`) — fail-closed against
///   `GovernanceService` decisions: only `.allowed` flips to true; any
///   `.requiresVote`, `.denied`, or thrown error keeps it false. The view
///   uses this to enable/disable controls.
/// - **Optimistic toggle** (`setEnabled`) — applies the toggle locally then
///   awaits the repository. On failure, reverts the local state and surfaces
///   an RLS-aware Spanish error message.
/// - **Pending votes map** — populated alongside `rules` so the view can
///   render a "voto en curso" badge.
/// - **`openRepealVote`** — convenience over `VoteRepository.startVote`
///   for `.ruleRepeal`. The migration `archive_rule_on_repeal_pass` (00026)
///   archives the rule on resolution; we just open the vote.
@Observable @MainActor
final class EditRulesCoordinator {
    private(set) var rules: [GroupRule] = []
    private(set) var pendingVotes: [UUID: PendingVote] = [:]
    private(set) var isLoading: Bool = false
    private(set) var error: String?
    private(set) var canEditRules: Bool = false
    private(set) var inFlightToggleIDs: Set<UUID> = []

    let group: Group
    private let currentMember: Member
    private let governance: any GovernanceServiceProtocol
    private let ruleRepo: any RuleRepository
    private let voteRepo: any VoteRepository
    /// Phase G3: optional dependency. Only required when the sheet is
    /// reached from an inbox row (`ruleChangeApplyPending`); the pencil
    /// flow doesn't pass one. Nil-safe — `resolvePendingAction` no-ops if
    /// the repo wasn't injected.
    private let userActionRepo: (any UserActionRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rules.edit")

    init(
        group: Group,
        currentMember: Member,
        governance: any GovernanceServiceProtocol,
        ruleRepo: any RuleRepository,
        voteRepo: any VoteRepository,
        userActionRepo: (any UserActionRepository)? = nil
    ) {
        self.group = group
        self.currentMember = currentMember
        self.governance = governance
        self.ruleRepo = ruleRepo
        self.voteRepo = voteRepo
        self.userActionRepo = userActionRepo
    }

    /// Refreshes governance, rules, and pending votes. Fail-closed: any
    /// governance throw or non-`.allowed` decision leaves `canEditRules`
    /// false.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

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
            let all = try await ruleRepo.list(groupId: group.id)
            // Mirror RulesCoordinator: prefer platform-shape rows; fall back
            // to the full list if there are no platform-shape rows yet.
            let platformShape = all.filter { !$0.consequences.isEmpty }
            rules = platformShape.isEmpty ? all : platformShape

            var pending: [UUID: PendingVote] = [:]
            for r in rules {
                if let v = try? await ruleRepo.pendingRepealVote(ruleId: r.id, groupId: group.id) {
                    pending[r.id] = v
                }
            }
            pendingVotes = pending
        } catch {
            log.warning("rules load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    /// Optimistic toggle: flips the row locally, attempts the persistence
    /// call, and reverts the local change on failure. The view subscribes to
    /// `rules` and `inFlightToggleIDs` to render a spinner / disabled state.
    func setEnabled(rule: GroupRule, enabled: Bool) async {
        inFlightToggleIDs.insert(rule.id)
        defer { inFlightToggleIDs.remove(rule.id) }

        let originalIndex = rules.firstIndex(where: { $0.id == rule.id })
        if let i = originalIndex {
            rules[i] = rules[i].withEnabled(enabled)
        }

        do {
            try await ruleRepo.setEnabled(ruleId: rule.id, enabled: enabled)
        } catch {
            log.warning("setEnabled failed: \(error.localizedDescription)")
            if let i = originalIndex {
                rules[i] = rules[i].withEnabled(!enabled)
            }
            self.error = mapMutationError(error)
        }
    }

    /// Persists a new flat fine amount. Caller must pre-validate via
    /// `rule.fineShape == .flat`; the repo also rejects with
    /// `.notFlatFine` for safety.
    func setFlatFineAmount(rule: GroupRule, amount: Int) async {
        do {
            try await ruleRepo.setFlatFineAmount(rule: rule, amount: amount)
            await refresh()
        } catch RulesRepositoryError.notFlatFine {
            self.error = "Esta regla tiene multa escalonada; se editará en una próxima versión."
        } catch {
            log.warning("setFlatFineAmount failed: \(error.localizedDescription)")
            self.error = mapMutationError(error)
        }
    }

    /// Opens a `rule_repeal` vote via `VoteRepository.startVote`. The vote
    /// machinery emits `voteOpened` immediately; the `archive_rule_on_repeal_pass`
    /// trigger (migration 00026) archives the rule when `finalize_vote`
    /// resolves `passed`.
    func openRepealVote(rule: GroupRule) async {
        do {
            _ = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .ruleRepeal,
                referenceId: rule.id,
                title: "Archivar: \(rule.title)",
                description: nil,
                payload: JSONConfig.empty
            )
            await refresh()
        } catch {
            log.warning("startVote failed: \(error.localizedDescription)")
            self.error = mapMutationError(error)
        }
    }

    /// Phase G3: resolves the inbox `UserAction` that opened this sheet.
    /// Called from `EditRuleSheet.commitAmount` after a successful save.
    /// Idempotent on the repo side — already-resolved actions are no-ops.
    /// Errors are logged but not surfaced; the rule edit already succeeded
    /// and inbox refresh will retry resolution on next load.
    func resolvePendingAction(_ id: UUID) async {
        guard let userActionRepo else { return }
        do {
            try await userActionRepo.resolve(actionId: id)
        } catch {
            log.warning("resolvePendingAction failed: \(error.localizedDescription)")
        }
    }

    /// Maps repository mutation errors to user-facing Spanish copy. RLS
    /// denials (Postgres SQLSTATE `42501` or any "policy" mention) get a
    /// "governance changed — pull to refresh" hint; everything else falls
    /// through to a generic retry message.
    private func mapMutationError(_ error: Error) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("policy") || message.contains("42501") {
            return "La gobernanza del grupo cambió. Tirá pull-to-refresh para ver los permisos actuales."
        }
        return "No se pudo guardar el cambio. Probá de nuevo."
    }
}
