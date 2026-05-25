import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Coordinator del `CreateRuleRepealSheet`. Abre una votación
/// `vote_type = ruleRepeal` que, si pasa, archiva la regla
/// referenciada (trigger SQL `archive_rule_on_repeal_pass`, mig 00347).
///
/// V1 minimal: una regla + una razón. Sin monto, sin metadata extra.
/// `referenceId = rule.id`. Payload empty `{}` — server-side el trigger
/// solo necesita la referencia + el resultado del voto.
///
/// Validation:
/// - selectedRule != nil
/// - reason trimmed length ∈ [5, 200]
@Observable @MainActor
public final class CreateRuleRepealCoordinator {
    public let group: Group
    public let member: Member
    public let availableRules: [GroupRule]
    private let voteRepo: any VoteRepository
    private let governance: any GovernanceServiceProtocol
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-create")

    public var selectedRule: GroupRule?
    public var reason: String = ""
    public var durationHours: Int = 72

    public private(set) var isSubmitting: Bool = false
    public private(set) var error: String?
    public private(set) var createdVoteId: UUID?

    public static let reasonMinLength = 5
    public static let reasonMaxLength = 200

    public var canSubmit: Bool {
        guard selectedRule != nil else { return false }
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.count >= Self.reasonMinLength
            && r.count <= Self.reasonMaxLength
            && !isSubmitting
    }

    public init(
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

    public func submit() async {
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

            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .ruleRepeal,
                referenceId: rule.id,
                title: "Archivar: \(rule.name)",
                description: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                payload: .object([:]),
                isAnonymous: false
            )
            createdVoteId = voteId
        } catch {
            self.error = "No pudimos abrir el voto: \(error.localizedDescription)"
            log.warning("create rule repeal failed: \(error.localizedDescription)")
        }
    }

    public func clearError() { error = nil }
}
