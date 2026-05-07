import Foundation
import Observation
import OSLog

/// Coordinator del CreateRuleChangeSheet. V1 solo permite cambiar el monto
/// flat de una regla existente — trigger / conditions / consequences NO son
/// modificables desde el sheet (eso requiere `EditRulesCoordinator`). El
/// payload del voto es `{ current_amount, proposed_amount }` y el
/// `referenceId` es el `rule.id` real (no sintético).
///
/// Validation:
/// - selectedRule != nil
/// - proposedAmount > 0 y diferente del actual
/// - reason trimmed length ∈ [5, 200]
@Observable @MainActor
final class CreateRuleChangeCoordinator {
    let group: Group
    let member: Member
    let availableRules: [GroupRule]
    private let voteRepo: any VoteRepository
    private let governance: any GovernanceServiceProtocol
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-create")

    var selectedRule: GroupRule?
    var proposedAmount: Int = 0
    var reason: String = ""
    var durationHours: Int = 72

    private(set) var isSubmitting: Bool = false
    private(set) var error: String?
    private(set) var createdVoteId: UUID?

    static let reasonMinLength = 5
    static let reasonMaxLength = 200

    var canSubmit: Bool {
        guard let rule = selectedRule else { return false }
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.count >= Self.reasonMinLength
            && r.count <= Self.reasonMaxLength
            && proposedAmount > 0
            && proposedAmount != currentAmount(for: rule)
            && !isSubmitting
    }

    init(
        group: Group,
        member: Member,
        availableRules: [GroupRule],
        voteRepo: any VoteRepository,
        governance: any GovernanceServiceProtocol
    ) {
        self.group = group
        self.member = member
        self.availableRules = availableRules
        self.voteRepo = voteRepo
        self.governance = governance
    }

    func submit() async {
        guard canSubmit, let rule = selectedRule else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        error = nil

        do {
            let decision = try await governance.canPerform(
                .createVotes, member: member, in: group, context: nil
            )
            if case .denied(let reason) = decision {
                error = "No tienes permiso para crear votaciones: \(reason)"
                return
            }

            let current = currentAmount(for: rule)
            let payload: JSONConfig = .object([
                "current_amount":  .int(current),
                "proposed_amount": .int(proposedAmount),
            ])

            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .ruleChange,
                referenceId: rule.id,
                title: "Cambio: \(rule.title)",
                description: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                payload: payload
            )
            createdVoteId = voteId
        } catch {
            self.error = "No pudimos abrir el voto: \(error.localizedDescription)"
            log.warning("create rule change failed: \(error.localizedDescription)")
        }
    }

    /// Read base amount from `fineShape`. `.flat` returns the amount,
    /// `.escalating` returns the base. `.none` and `.unknown` return 0.
    private func currentAmount(for rule: GroupRule) -> Int {
        switch rule.fineShape {
        case .flat(let amount):           return amount
        case .escalating(let base, _, _): return base
        case .none, .unknown:             return 0
        }
    }

    func clearError() { error = nil }
}
