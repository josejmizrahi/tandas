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
    private let analytics: (any AnalyticsService)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-detail")

    private(set) var myCast: VoteCast?
    private(set) var counts: VoteCounts?
    private(set) var isLoading: Bool = false
    private(set) var isCasting: Bool = false
    private(set) var error: CoordinatorError?

    var alreadyVoted: Bool { (myCast?.choice ?? .pending) != .pending }
    var voteIsClosed: Bool { vote.status != .open }

    init(
        vote: Vote,
        group: Group,
        userMemberId: UUID,
        voteRepo: any VoteRepository,
        castRepo: any VoteCastRepository,
        analytics: (any AnalyticsService)? = nil
    ) {
        self.vote = vote
        self.group = group
        self.userMemberId = userMemberId
        self.voteRepo = voteRepo
        self.castRepo = castRepo
        self.analytics = analytics
    }

    func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let myCastTask = castRepo.myCast(voteId: vote.id, userMemberId: userMemberId)
        async let countsTask = castRepo.counts(voteId: vote.id)
        do {
            myCast = try await myCastTask
            counts = try await countsTask
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar el voto")
            log.warning("vote detail refresh failed: \(error.localizedDescription)")
        }
    }

    func cast(_ choice: VoteChoice) async {
        guard !isCasting else { return }
        isCasting = true
        defer { isCasting = false }

        do {
            try await castRepo.cast(voteId: vote.id, choice: choice)
            // Beta 1 instrumentation (Plans/Active/Beta1.md §4):
            // capture every successful cast with vote_type so we can
            // split fine_appeal from rule_change / general_proposal.
            if let analytics {
                let beta = BetaAnalytics(analytics: analytics)
                await beta.voteCast(
                    voteId: vote.id,
                    voteType: vote.voteType.rawValue,
                    choice: choice.rawValue
                )
            }
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
                self.error = CoordinatorError(
                    title: "Voto cerrado",
                    message: "Este voto ya cerró. Refrescamos resultados.",
                    isRetryable: false
                )
            } else {
                self.error = CoordinatorError(
                    title: "No pudimos registrar tu voto",
                    message: msg,
                    isRetryable: true
                )
            }
        }
    }

    func clearError() { error = nil }
}
