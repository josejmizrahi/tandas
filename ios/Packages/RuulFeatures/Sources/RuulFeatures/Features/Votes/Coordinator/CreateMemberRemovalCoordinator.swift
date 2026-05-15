import Foundation
import Observation
import OSLog
import RuulCore

/// Coordinator del CreateMemberRemovalSheet. Carga la lista de miembros
/// activos del grupo (excluyendo al creador), expone el picker de target,
/// la razón y la duración, y llama a `start_vote(vote_type=member_removal)`.
///
/// Validation:
/// - `target` != nil
/// - `reason` trimmed length >= 30
///
/// Adaptation from plan: `VoteRepository.startVote` does not accept a
/// `durationHours` parameter — the server enforces its own default. The
/// `durationHours` UI field is kept for display purposes only and is not
/// sent to the RPC.
@Observable @MainActor
public final class CreateMemberRemovalCoordinator {
    public let group: Group
    /// Row ID (group_members.id) of the member opening the vote.
    public let creatorMemberId: UUID
    private let voteRepo: any VoteRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote.member-removal")

    /// Eligible targets loaded from `groupsRepo.membersWithProfiles`.
    public var members: [MemberWithProfile] = []
    /// Currently selected removal target.
    public var target: MemberWithProfile?
    /// Minimum 30 chars required before submit is enabled.
    public var reason: String = ""
    public var durationHours: Int = 72
    public private(set) var isLoading: Bool = false
    public private(set) var isSubmitting: Bool = false
    public private(set) var error: CoordinatorError?
    public private(set) var createdVoteId: UUID?

    /// `prefilledTarget` is set when the sheet opens from MembersAdminView
    /// swipe — skips the picker and lands straight on the reason form.
    public init(
        group: Group,
        creatorMemberId: UUID,
        prefilledTarget: MemberWithProfile? = nil,
        voteRepo: any VoteRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.group = group
        self.creatorMemberId = creatorMemberId
        self.target = prefilledTarget
        self.voteRepo = voteRepo
        self.groupsRepo = groupsRepo
    }

    /// Loads active members minus the creator. Call once on `.task`.
    public func loadMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await groupsRepo.membersWithProfiles(of: group.id)
            // Exclude the coordinator creator and inactive members.
            members = all.filter { $0.member.active && $0.member.id != creatorMemberId }
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los miembros")
        }
    }

    public var isReadyToSubmit: Bool {
        target != nil
            && reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30
            && !isSubmitting
    }

    public func submit() async {
        guard let target, isReadyToSubmit else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "Quitar a \(target.displayName)"
        // `target.member.id` = group_members row id (UUID in group_members.id).
        // `target.member.userId` = auth.users.id — used as referenceId so
        // VoteDetailCoordinator + MemberRemovalVoteBody can correlate the vote.
        let payload: JSONConfig = .object([
            "target_member_id": .string(target.member.id.uuidString.lowercased()),
            "reason": .string(trimmedReason)
        ])

        do {
            let voteId = try await voteRepo.startVote(
                groupId: group.id,
                voteType: .memberRemoval,
                referenceId: target.member.userId,
                title: title,
                description: trimmedReason,
                payload: payload
            )
            createdVoteId = voteId
        } catch {
            log.warning("memberRemoval submit failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos iniciar el voto")
        }
    }

    public func clearError() { error = nil }
}
