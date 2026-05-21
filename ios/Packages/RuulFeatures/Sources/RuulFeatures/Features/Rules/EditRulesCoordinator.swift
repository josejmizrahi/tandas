import Foundation
import OSLog
import RuulUI
import RuulCore

/// Editor-side coordinator for the Reglas tab. Owns:
///
/// - **Edit mode** (`editMode`) — three-state policy-driven gate:
///   `.directWrite` (member can edit and changes apply immediately),
///   `.voteGated` (member can propose changes which open a vote), or
///   `.readOnly` (no edit path). Driven by `GroupPolicyRepository.resolve`
///   against `target_action = rule.toggle`.
/// - **Optimistic toggle** (`setIsActive`) — applies the toggle locally then
///   awaits the `InterceptingRuleRepository`. On `.vote` outcome reverts
///   the optimistic flip and surfaces a `voteOpened` banner. On `.applied`
///   keeps the new state. On `.adminOnly` or denial, reverts and shows an
///   error.
/// - **Pending votes map** — populated alongside `rules` so the view can
///   render a "voto en curso" badge.
/// - **`openRepealVote`** — convenience over `VoteRepository.startVote`
///   for `.ruleRepeal`. The migration `archive_rule_on_repeal_pass` (00026)
///   archives the rule on resolution; we just open the vote.
@Observable @MainActor
public final class EditRulesCoordinator {

    public enum EditMode: Sendable, Hashable {
        /// Member can edit and writes apply directly.
        case directWrite
        /// Member can edit but every change opens a vote first. `thresholdPercent`
        /// is the % "yes" required to pass.
        case voteGated(thresholdPercent: Int)
        /// Member can view but cannot edit. UI disables controls.
        case readOnly
    }

    public enum Banner: Sendable, Hashable {
        /// A vote was just opened for a proposed change. `voteId` deeplinks
        /// to the detail view.
        case voteOpened(voteId: UUID)
    }

    public private(set) var rules: [GroupRule] = []
    public private(set) var pendingVotes: [UUID: PendingVote] = [:]
    public private(set) var isLoading: Bool = false
    public private(set) var error: String?
    public private(set) var editMode: EditMode = .readOnly
    public private(set) var banner: Banner?
    public private(set) var inFlightToggleIDs: Set<UUID> = []

    /// Backwards-compat alias for legacy callers that read a bool.
    /// True when `editMode` permits any edit path (direct or vote-gated).
    public var canEditRules: Bool {
        switch editMode {
        case .directWrite, .voteGated: return true
        case .readOnly:                return false
        }
    }

    public let group: Group
    private let currentMember: Member
    private let actorUserId: UUID
    private let governance: any GovernanceServiceProtocol
    private let policyRepo: any GroupPolicyRepository
    private let ruleRepo: any RuleRepository
    private let voteRepo: any VoteRepository
    private let userActionRepo: (any UserActionRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rules.edit")

    /// Lazy interceptor — constructed on first mutation so we can compose
    /// `ruleRepo` + `policyRepo` + `voteRepo` with the actor's user id.
    private var interceptor: InterceptingRuleRepository {
        InterceptingRuleRepository(
            inner: ruleRepo,
            policyRepo: policyRepo,
            voteRepo: voteRepo,
            actorUserId: actorUserId
        )
    }

    public init(
        group: Group,
        currentMember: Member,
        actorUserId: UUID,
        governance: any GovernanceServiceProtocol,
        policyRepo: any GroupPolicyRepository,
        ruleRepo: any RuleRepository,
        voteRepo: any VoteRepository,
        userActionRepo: (any UserActionRepository)? = nil
    ) {
        self.group = group
        self.currentMember = currentMember
        self.actorUserId = actorUserId
        self.governance = governance
        self.policyRepo = policyRepo
        self.ruleRepo = ruleRepo
        self.voteRepo = voteRepo
        self.userActionRepo = userActionRepo
    }

    /// Refreshes edit mode, rules, and pending votes. Fail-closed: any
    /// resolve throw or unrecognized decision yields `.readOnly`.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let decision = try await policyRepo.resolve(
                groupId: group.id,
                actorUserId: actorUserId,
                action: .ruleToggle,
                targetPayload: [:]
            )
            switch decision {
            case .allowed:
                editMode = .directWrite
            case .voteRequired(_, let threshold, _):
                editMode = .voteGated(thresholdPercent: threshold)
            case .adminOnly, .denied:
                editMode = .readOnly
            }
        } catch {
            log.warning("policy resolve failed: \(error.localizedDescription)")
            editMode = .readOnly
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
            self.error = error.ruulUserMessage
        }
    }

    /// Optimistic toggle: flips the row locally, calls the interceptor,
    /// reconciles based on the outcome.
    public func setIsActive(rule: GroupRule, isActive: Bool) async {
        inFlightToggleIDs.insert(rule.id)
        defer { inFlightToggleIDs.remove(rule.id) }

        let originalIndex = rules.firstIndex(where: { $0.id == rule.id })
        let currentIsActive = rule.isActive
        if let i = originalIndex {
            rules[i] = rules[i].withIsActive(isActive)
        }

        do {
            let outcome = try await interceptor.setIsActive(
                ruleId: rule.id,
                isActive: isActive,
                groupId: group.id,
                currentIsActive: currentIsActive
            )
            switch outcome {
            case .applied:
                // Local optimistic state already matches the new server state.
                break
            case .vote(let voteId):
                // Revert local — the change isn't applied until the vote resolves.
                if let i = originalIndex {
                    rules[i] = rules[i].withIsActive(currentIsActive)
                }
                banner = .voteOpened(voteId: voteId)
                await refresh()
            case .adminOnly:
                if let i = originalIndex {
                    rules[i] = rules[i].withIsActive(currentIsActive)
                }
                self.error = "Solo los fundadores pueden cambiar esta regla."
            }
        } catch let mutation as RuleMutationError {
            if let i = originalIndex {
                rules[i] = rules[i].withIsActive(currentIsActive)
            }
            self.error = mapMutationError(mutation)
        } catch {
            log.warning("setIsActive failed: \(error.localizedDescription)")
            if let i = originalIndex {
                rules[i] = rules[i].withIsActive(currentIsActive)
            }
            self.error = mapGenericError(error)
        }
    }

    /// Persists a new flat fine amount. Caller must pre-validate via
    /// `FineConsequenceParser.shape(of: rule.consequences) == .flat(...)`;
    /// the repo also rejects with `.notFlatFine`.
    public func setFlatFineAmount(rule: GroupRule, amount: Int) async {
        let currentAmount: Int = {
            if case .flat(let value) = FineConsequenceParser.shape(of: rule.consequences) {
                return value
            }
            return 0
        }()

        do {
            let outcome = try await interceptor.setFlatFineAmount(
                rule: rule,
                amount: amount,
                currentAmount: currentAmount
            )
            switch outcome {
            case .applied:
                await refresh()
            case .vote(let voteId):
                banner = .voteOpened(voteId: voteId)
                await refresh()
            case .adminOnly:
                self.error = "Solo los fundadores pueden cambiar el monto."
            }
        } catch RulesRepositoryError.notFlatFine {
            self.error = "Esta regla tiene multa escalonada; se editará en una próxima versión."
        } catch let mutation as RuleMutationError {
            self.error = mapMutationError(mutation)
        } catch {
            log.warning("setFlatFineAmount failed: \(error.localizedDescription)")
            self.error = mapGenericError(error)
        }
    }

    /// Opens a `rule_repeal` vote. The vote machinery emits `voteOpened`
    /// immediately; the `archive_rule_on_repeal_pass` trigger (mig 00026)
    /// archives the rule when finalize resolves passed.
    public func openRepealVote(rule: GroupRule) async {
        do {
            _ = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .ruleRepeal,
                referenceId: rule.id,
                title: "Archivar: \(rule.name)",
                description: nil,
                payload: JSONConfig.empty,
                isAnonymous: false
            )
            await refresh()
        } catch {
            log.warning("startVote failed: \(error.localizedDescription)")
            self.error = mapGenericError(error)
        }
    }

    public func clearBanner() { banner = nil }
    public func clearError() { error = nil }

    /// Resolves a pending inbox action (Phase G3).
    public func resolvePendingAction(_ id: UUID) async {
        guard let userActionRepo else { return }
        do {
            try await userActionRepo.resolve(actionId: id)
        } catch {
            log.warning("resolvePendingAction failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Error mapping

    private func mapMutationError(_ error: RuleMutationError) -> String {
        switch error {
        case .denied(let reason):
            return "No tienes permiso: \(reason)"
        case .voteOpenFailed(let detail):
            return "No pudimos abrir la votación: \(detail)"
        case .underlying(let detail):
            return "Algo salió mal: \(detail)"
        }
    }

    private func mapGenericError(_ error: Error) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("policy") || message.contains("42501") {
            return "Las decisiones del grupo cambiaron. Tirá pull-to-refresh para ver los permisos actuales."
        }
        return "No se pudo guardar el cambio. Probá de nuevo."
    }
}
