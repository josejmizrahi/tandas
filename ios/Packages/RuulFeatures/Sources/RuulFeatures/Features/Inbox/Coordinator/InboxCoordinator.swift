import Foundation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class InboxCoordinator {
    public private(set) var actions: [UserAction] = []
    public private(set) var resolvedActions: [UserAction] = []
    public private(set) var groupsById: [UUID: Group] = [:]
    public private(set) var isLoading: Bool = false
    public private(set) var error: CoordinatorError?
    /// True después de que `refresh()` completó al menos una vez. Permite
    /// distinguir "primera carga" de "loaded empty" cuando `actions == []`.
    /// Consumido por `LoadPhase.fromCollection` en la computed `phase`.
    public private(set) var hasLoaded: Bool = false

    private let userId: UUID
    /// When nil (default in 14.2), the inbox is cross-group: every pending
    /// UserAction for the user across every group they belong to. Pass an
    /// id to scope to a single group.
    private let groupId: UUID?
    private let userActionRepo: any UserActionRepository
    private let groupsRepo: (any GroupsRepository)?
    /// FASE 3 C.2 surface 2 (RSVP inline): when injected, the inbox can
    /// commit `.rsvpPending` actions inline (Voy / No voy chips) without
    /// pushing the event detail. Optional so preview / mock paths can
    /// instantiate the coordinator without rewiring AppState.
    private let rsvpRepo: (any RSVPRepository)?
    /// FASE 3 C.2 surface 2 (appeal vote inline): when injected, the inbox
    /// can cast a fine-appeal vote (Mantener multa / Anular multa) without
    /// pushing the vote detail. Optional so preview / mock paths still
    /// instantiate the coordinator without rewiring AppState.
    private let appealRepo: (any AppealRepository)?
    /// Beta 1 W4 F-4.5: nil-safe analytics injection so `inbox_action_resolved`
    /// fires when the user taps through a row. Default nil keeps preview /
    /// mock callers working without rewiring AppState.
    private let analytics: (any AnalyticsService)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "inbox")

    /// Beta 1 W3 E-3.1: subscribes to the cross-device feed so that when
    /// the user resolves an action on device A, device B's inbox refreshes
    /// within one realtime tick. nil for previews / mock paths.
    // Swift 6: deinit is nonisolated, so the cancellation handle must be
    // reachable from nonisolated context. Task is Sendable; the
    // nonisolated(unsafe) annotation is just an assertion that we only
    // assign during the main-actor-isolated init and read in deinit.
    nonisolated(unsafe) private var changeFeedTask: Task<Void, Never>?

    public init(
        userId: UUID,
        groupId: UUID?,
        userActionRepo: any UserActionRepository,
        groupsRepo: (any GroupsRepository)? = nil,
        rsvpRepo: (any RSVPRepository)? = nil,
        appealRepo: (any AppealRepository)? = nil,
        changeFeed: (any MultiDeviceChangeFeed)? = nil,
        analytics: (any AnalyticsService)? = nil
    ) {
        self.userId = userId
        self.groupId = groupId
        self.userActionRepo = userActionRepo
        self.groupsRepo = groupsRepo
        self.rsvpRepo = rsvpRepo
        self.appealRepo = appealRepo
        self.analytics = analytics
        if let feed = changeFeed {
            self.changeFeedTask = Task { [weak self] in
                for await change in feed.changes {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if change.table == .userAction {
                        await self.refresh()
                    }
                }
            }
        }
    }

    deinit { changeFeedTask?.cancel() }

    /// Adapter para `AsyncContentView`. Deriva el `LoadPhase` desde los
    /// campos `@Observable` que ya mantenemos.
    public var phase: LoadPhase<[UserAction]> {
        LoadPhase.fromCollection(
            value: actions,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            async let actionsTask = userActionRepo.pending(userId: userId, groupId: groupId)
            async let groupsTask: [Group] = {
                guard let repo = groupsRepo else { return [] }
                return (try? await repo.listMine()) ?? []
            }()
            let (loadedActions, loadedGroups) = try await (actionsTask, groupsTask)
            self.actions = loadedActions
            self.groupsById = Dictionary(uniqueKeysWithValues: loadedGroups.map { ($0.id, $0) })
        } catch {
            log.warning("inbox load failed: \(error.localizedDescription)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tu inbox")
        }
    }

    public func clearError() { error = nil }

    /// Fetches the user's most recent resolved actions. Cross-group.
    /// Drives the "Resueltas" chip in InboxView.
    public func loadResolved(limit: Int = 50) async {
        do {
            resolvedActions = try await userActionRepo.resolved(userId: userId, limit: limit)
        } catch {
            log.warning("loadResolved failed: \(error.localizedDescription)")
            // resolvedActions stays as-is on failure
        }
    }

    public func groupName(for action: UserAction) -> String? {
        groupsById[action.groupId]?.name
    }

    /// Resolves every currently visible pending action in sequence.
    /// Returns the count of successfully resolved items.
    public func resolveAll() async -> Int {
        let snapshot = actions
        var count = 0
        for action in snapshot {
            do {
                try await userActionRepo.resolve(actionId: action.id)
                count += 1
            } catch {
                log.warning("resolveAll: failed for \(action.id): \(error.localizedDescription)")
            }
        }
        await refresh()
        return count
    }

    /// Quick-resolve an action from a swipe or context menu without opening it.
    /// Removes the row immediately for instant feedback, then fires the repo call.
    public func resolveQuick(_ actionId: UUID) async {
        actions.removeAll { $0.id == actionId }
        do {
            try await userActionRepo.resolve(actionId: actionId)
        } catch {
            log.warning("resolveQuick failed: \(error.localizedDescription)")
            // On failure: a subsequent refresh() will restore the row if still pending.
            await refresh()
        }
    }

    /// FASE 3 C.2 surface 2: commits an RSVP from the inbox row without
    /// pushing the event detail. Optimistic — removes the row immediately
    /// so the inbox feels responsive; if the RPC fails, refresh() restores
    /// the row (server-side projection is the source of truth). The
    /// `set_rsvp_v2` trigger resolves the `rsvpPending` UserAction
    /// server-side, so no separate resolve() call is needed on success.
    public func confirmRSVP(_ action: UserAction, status: RSVPStatus) async {
        guard action.actionType == .rsvpPending,
              let rsvpRepo
        else { return }
        let eventId = action.referenceId
        actions.removeAll { $0.id == action.id }
        do {
            _ = try await rsvpRepo.setRSVP(
                eventId: eventId,
                status: status,
                plusOnes: 0,
                reason: nil
            )
        } catch {
            log.warning("confirmRSVP failed: \(error.localizedDescription)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar tu respuesta")
            await refresh()
        }
    }

    /// FASE 3 C.2 surface 2: casts a fine-appeal vote from the inbox row
    /// without pushing the vote detail. `action.referenceId` carries the
    /// vote id (mig 00163 — `appealVotePending.reference_id = vote_id`).
    /// `cast_vote` writes a vote_casts row; the post-insert trigger then
    /// auto-resolves the `appealVotePending` UserAction server-side, so
    /// no resolve() call is needed on success. Refresh restores the row
    /// on RPC failure.
    public func castAppealVote(_ action: UserAction, choice: AppealVoteChoice) async {
        guard action.actionType == .appealVotePending,
              let appealRepo
        else { return }
        let voteId = action.referenceId
        actions.removeAll { $0.id == action.id }
        do {
            try await appealRepo.castVote(appealId: voteId, choice: choice)
        } catch {
            log.warning("castAppealVote failed: \(error.localizedDescription)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar tu voto")
            await refresh()
        }
    }

    /// Mark an action resolved when the user opens it. Server triggers also
    /// auto-resolve in some cases (e.g. casting an appeal vote resolves the
    /// `appealVotePending` row), so this is mostly for "tapped" semantics.
    public func resolve(actionId: UUID) async {
        // Capture the action_type before the local removal so we can emit
        // an accurate telemetry event even after `actions` no longer holds
        // the row.
        let actionType = actions.first(where: { $0.id == actionId })?.actionType
        do {
            try await userActionRepo.resolve(actionId: actionId)
            actions.removeAll { $0.id == actionId }
            // Beta 1 W4 F-4.5: per-resolution telemetry. Drops silently
            // when analytics not injected (preview / mock paths).
            if let analytics, let actionType {
                let beta = BetaAnalytics(analytics: analytics)
                await beta.inboxActionResolved(actionType: actionType.rawValue)
            }
        } catch {
            log.warning("resolve failed: \(error.localizedDescription)")
        }
    }
}
