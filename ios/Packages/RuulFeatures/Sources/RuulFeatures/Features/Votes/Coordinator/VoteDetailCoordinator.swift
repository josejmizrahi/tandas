import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Coordinator del detail view de un Vote. Fetcha myCast + counts en
/// parallel, expone derived flags `alreadyVoted` y `voteIsClosed`,
/// orquesta cast con manejo de edge case "vote finalizes mid-cast".
@Observable @MainActor
public final class VoteDetailCoordinator {
    public let vote: Vote
    public let group: Group
    private let userMemberId: UUID
    /// Caller's role in the group ("founder" | "admin" | "member").
    /// Used to gate manual-finalize. Defaults to "member" when not supplied.
    private let myRole: String
    private let voteRepo: any VoteRepository
    private let castRepo: any VoteCastRepository
    private let analytics: (any AnalyticsService)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "vote-detail")

    public private(set) var myCast: VoteCast?
    public private(set) var counts: VoteCounts?
    public private(set) var isLoading: Bool = false
    public private(set) var isCasting: Bool = false
    public private(set) var error: CoordinatorError?

    public var alreadyVoted: Bool { (myCast?.choice ?? .pending) != .pending }
    public var voteIsClosed: Bool { vote.status != .open }

    // MARK: - Admin / creator action visibility

    /// True when the caller is a founder/admin — may manually finalize.
    public var isCurrentUserAdmin: Bool {
        myRole == "founder" || myRole == "admin"
    }

    /// True when the caller created this vote.
    public var isCurrentUserCreator: Bool {
        vote.createdByMemberId == userMemberId
    }

    /// Show "Finalizar" button: vote is open, past closes_at, caller is admin.
    public var shouldShowFinalize: Bool {
        vote.status == .open && Date.now > vote.closesAt && isCurrentUserAdmin
    }

    /// Show "Cancelar" button: vote is open, caller is creator, zero real casts.
    public var shouldShowCancel: Bool {
        guard vote.status == .open && isCurrentUserCreator else { return false }
        let c = counts
        return (c?.inFavor ?? 0) + (c?.against ?? 0) + (c?.abstained ?? 0) == 0
    }

    // MARK: - Admin / creator action state

    public private(set) var isFinalizingManually: Bool = false
    public private(set) var isCancellingVote: Bool = false

    /// Beta 1 W3 E-3.1: multi-device sync. Listens for `votes` or
    /// `vote_casts` changes; refreshes when one matches this vote.
    // Swift 6: deinit is nonisolated. Task is Sendable; the
    // nonisolated(unsafe) annotation asserts the property is only mutated
    // inside the main-actor-isolated init.
    nonisolated(unsafe) private var changeFeedTask: Task<Void, Never>?

    public init(
        vote: Vote,
        group: Group,
        userMemberId: UUID,
        myRole: String = "member",
        voteRepo: any VoteRepository,
        castRepo: any VoteCastRepository,
        analytics: (any AnalyticsService)? = nil,
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.vote = vote
        self.group = group
        self.userMemberId = userMemberId
        self.myRole = myRole
        self.voteRepo = voteRepo
        self.castRepo = castRepo
        self.analytics = analytics
        if let feed = changeFeed {
            let myVoteId = vote.id
            self.changeFeedTask = Task { [weak self] in
                for await change in feed.changes {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    // `votes` events filter by id; `vote_casts` events
                    // arrive only for the user's own casts (RLS-scoped)
                    // so any cast change is worth refreshing the tally.
                    if (change.table == .vote && change.recordId == myVoteId)
                        || change.table == .voteCast {
                        await self.refresh()
                    }
                }
            }
        }
    }

    deinit { changeFeedTask?.cancel() }

    public func refresh() async {
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

    public func cast(_ choice: VoteChoice) async {
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

    public func finalizeManually() async {
        guard !isFinalizingManually else { return }
        isFinalizingManually = true
        defer { isFinalizingManually = false }
        do {
            _ = try await voteRepo.finalizeVote(voteId: vote.id)
            await refresh()
        } catch {
            let msg = error.localizedDescription
            log.warning("manual finalize failed: \(msg)")
            self.error = CoordinatorError(
                title: "No se pudo finalizar",
                message: msg,
                isRetryable: true
            )
        }
    }

    public func cancelVote() async {
        guard !isCancellingVote else { return }
        isCancellingVote = true
        defer { isCancellingVote = false }
        do {
            try await voteRepo.cancelVote(vote.id)
            await refresh()
        } catch {
            let msg = error.localizedDescription
            log.warning("cancel vote failed: \(msg)")
            self.error = CoordinatorError(
                title: "No se pudo cancelar",
                message: msg,
                isRetryable: false
            )
        }
    }

    public func clearError() { error = nil }
}
