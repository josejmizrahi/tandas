import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Coordinator del CreateGeneralProposalSheet. Form state + governance gate
/// + submit a `start_vote(vote_type=general_proposal)` con `referenceId`
/// sintético (UUID nuevo) y `payload=.empty` (V1 no requiere config extra).
///
/// Validation:
/// - title trimmed length ∈ [5, 100]
/// - description ≤ 500 chars
/// - durationHours ∈ [1, 168] (UI gating; server clampa)
@Observable @MainActor
public final class CreateGeneralProposalCoordinator {
    public let group: Group
    public let member: Member
    private let voteRepo: any VoteRepository
    private let governance: any GovernanceServiceProtocol
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-create")

    public var title: String = ""
    public var description: String = ""
    public var durationHours: Int = 72
    public private(set) var isSubmitting: Bool = false
    public private(set) var error: String?
    public private(set) var createdVoteId: UUID?

    public static let titleMinLength = 5
    public static let titleMaxLength = 100
    public static let descriptionMaxLength = 500

    public var canSubmit: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= Self.titleMinLength
            && t.count <= Self.titleMaxLength
            && description.count <= Self.descriptionMaxLength
            && !isSubmitting
    }

    public init(
        group: Group,
        member: Member,
        voteRepo: any VoteRepository,
        governance: any GovernanceServiceProtocol
    ) {
        self.group = group
        self.member = member
        self.voteRepo = voteRepo
        self.governance = governance
    }

    public func submit() async {
        guard canSubmit else { return }
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

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .generalProposal,
                referenceId: UUID(),
                title: trimmedTitle,
                description: description.isEmpty ? nil : description,
                payload: .empty
            )
            createdVoteId = voteId
        } catch {
            self.error = "No pudimos abrir el voto: \(error.localizedDescription)"
            log.warning("create general proposal failed: \(error.localizedDescription)")
        }
    }

    public func clearError() { error = nil }
}
