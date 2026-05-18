import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Coordinator del OpenVotesListView. Lista cross-vote_type de votes
/// con status='open' del grupo activo. Sectiona por urgencia
/// (closing-soon < 24h vs other) para que el founder/miembros vean
/// primero lo que está por cerrar.
@Observable @MainActor
public final class OpenVotesCoordinator {
    public let group: Group
    private let voteRepo: any VoteRepository
    private let castRepo: (any VoteCastRepository)?
    private let userMemberId: UUID?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "votes")

    public private(set) var openVotes: [Vote] = []
    /// IDs of votes the user has already cast their ballot on (cast_at != nil).
    /// Empty when castRepo or userMemberId not provided (back-compat).
    public private(set) var castedVoteIds: Set<UUID> = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: CoordinatorError?
    public private(set) var lastRefreshedAt: Date?
    /// True después de que `refresh()` completó al menos una vez. Permite
    /// distinguir "primera carga" de "loaded empty" cuando `openVotes == []`.
    /// Consumido por `LoadPhase.fromCollection` en la computed `phase`.
    public private(set) var hasLoaded: Bool = false

    private let cacheTTL: TimeInterval = 60

    /// Beta 1 W3 E-3.1: multi-device sync. Listens for `votes` /
    /// `vote_casts` changes and triggers a refresh. nil in preview/mock.
    // Swift 6: deinit is nonisolated. Task is Sendable; the
    // nonisolated(unsafe) annotation asserts the property is only mutated
    // inside the main-actor-isolated init.
    nonisolated(unsafe) private var changeFeedTask: Task<Void, Never>?

    public init(
        group: Group,
        voteRepo: any VoteRepository,
        castRepo: (any VoteCastRepository)? = nil,
        userMemberId: UUID? = nil,
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.group = group
        self.voteRepo = voteRepo
        self.castRepo = castRepo
        self.userMemberId = userMemberId
        if let feed = changeFeed {
            self.changeFeedTask = Task { [weak self] in
                for await change in feed.changes {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if change.table == .vote || change.table == .voteCast {
                        await self.refresh(force: true)
                    }
                }
            }
        }
    }

    deinit { changeFeedTask?.cancel() }

    /// Adapter para `AsyncContentView`. Deriva el `LoadPhase` desde los
    /// campos `@Observable` que ya mantenemos.
    public var phase: LoadPhase<[Vote]> {
        LoadPhase.fromCollection(
            value: openVotes,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    public func refresh(force: Bool = false) async {
        if !force, let last = lastRefreshedAt,
           Date.now.timeIntervalSince(last) < cacheTTL {
            return
        }
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let votes = try await voteRepo.openVotes(for: group.id)
            openVotes = votes
            // Determine which of these I've already cast (cast_at != nil).
            // Done sequentially to keep the implementation simple — V1 group
            // size is small, # open votes is small. Phase 2 may switch to a
            // single bulk RPC if N grows.
            if let castRepo, let userMemberId {
                var casted: Set<UUID> = []
                for v in votes {
                    if let myCast = try? await castRepo.myCast(voteId: v.id, userMemberId: userMemberId),
                       myCast.castAt != nil {
                        casted.insert(v.id)
                    }
                }
                castedVoteIds = casted
            } else {
                castedVoteIds = []
            }
            lastRefreshedAt = .now
        } catch {
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los votos abiertos")
            log.warning("openVotes refresh failed: \(error.localizedDescription)")
        }
    }

    public func clearError() { error = nil }

    /// Votos abiertos donde el user todavía no casteó. Estos requieren acción.
    public var pending: [Vote] { openVotes.filter { !castedVoteIds.contains($0.id) } }
    /// Votos abiertos donde el user ya casteó. Sigue abierto pero ya actuó.
    public var voted: [Vote]   { openVotes.filter { castedVoteIds.contains($0.id) } }

    /// Has the user cast a ballot on this vote? Used by row presentation
    /// to render an "Ya votaste" check vs an "Pendiente de tu voto" CTA.
    public func hasCast(_ voteId: UUID) -> Bool { castedVoteIds.contains(voteId) }

    /// Sectioned by user-action status (Pendientes / Ya votaste). Replaces
    /// the previous urgency-based sectioning — urgency surfaces inside each
    /// row via "Cierra X" copy.
    public func sectioned() -> [(Section, [Vote])] {
        var result: [(Section, [Vote])] = []
        let p = pending
        let v = voted
        if !p.isEmpty { result.append((.pending, p)) }
        if !v.isEmpty { result.append((.voted, v)) }
        return result
    }

    public enum Section: Hashable {
        case pending
        case voted

        var title: String {
            switch self {
            case .pending: return "Pendientes de tu voto"
            case .voted:   return "Ya votaste"
            }
        }
    }
}
