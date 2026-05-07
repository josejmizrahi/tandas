import Foundation
import Observation
import OSLog

/// Coordinator del detail view de un Vote. Fetcha myCast + counts en
/// parallel, expone derived flags `alreadyVoted` y `voteIsClosed`,
/// orquesta cast con manejo de edge case "vote finalizes mid-cast".
@Observable @MainActor
final class VoteDetailCoordinator {
    let vote: Vote
    let group: Group
    private let userMemberId: UUID
    private let voteRepo: any VoteRepository
    private let castRepo: any VoteCastRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-detail")

    private(set) var myCast: VoteCast?
    private(set) var counts: VoteCounts?
    private(set) var isCasting: Bool = false
    private(set) var error: String?

    var alreadyVoted: Bool { (myCast?.choice ?? .pending) != .pending }
    var voteIsClosed: Bool { vote.status != .open }

    init(
        vote: Vote,
        group: Group,
        userMemberId: UUID,
        voteRepo: any VoteRepository,
        castRepo: any VoteCastRepository
    ) {
        self.vote = vote
        self.group = group
        self.userMemberId = userMemberId
        self.voteRepo = voteRepo
        self.castRepo = castRepo
    }

    func refresh() async {
        async let myCastTask = castRepo.myCast(voteId: vote.id, userMemberId: userMemberId)
        async let countsTask = castRepo.counts(voteId: vote.id)
        do {
            myCast = try await myCastTask
            counts = try await countsTask
            error = nil
        } catch {
            self.error = error.localizedDescription
            log.warning("vote detail refresh failed: \(error.localizedDescription)")
        }
    }

    func cast(_ choice: VoteChoice) async {
        guard !isCasting else { return }
        isCasting = true
        defer { isCasting = false }

        do {
            try await castRepo.cast(voteId: vote.id, choice: choice)
            await refresh()
        } catch {
            // Edge case: vote closed mid-cast. Surfaceamos copy claro
            // y refrescamos para mostrar el resultado final. Refresh first
            // (it clears `error` on success) and set the message afterward
            // so the surfaced copy survives.
            let msg = error.localizedDescription
            log.warning("cast failed: \(msg)")
            if msg.contains("vote closed") || msg.contains("not open") {
                await refresh()
                self.error = "Este voto ya cerró. Refrescamos resultados."
            } else {
                self.error = "No pudimos registrar tu voto: \(msg)"
            }
        }
    }

    func clearError() { error = nil }
}
