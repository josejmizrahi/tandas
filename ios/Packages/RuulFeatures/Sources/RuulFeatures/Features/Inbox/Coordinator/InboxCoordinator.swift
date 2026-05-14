import Foundation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class InboxCoordinator {
    public private(set) var actions: [UserAction] = []
    public private(set) var groupsById: [UUID: Group] = [:]
    public private(set) var isLoading: Bool = false
    public private(set) var error: CoordinatorError?

    private let userId: UUID
    /// When nil (default in 14.2), the inbox is cross-group: every pending
    /// UserAction for the user across every group they belong to. Pass an
    /// id to scope to a single group.
    private let groupId: UUID?
    private let userActionRepo: any UserActionRepository
    private let groupsRepo: (any GroupsRepository)?
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
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.userId = userId
        self.groupId = groupId
        self.userActionRepo = userActionRepo
        self.groupsRepo = groupsRepo
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

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
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

    public func groupName(for action: UserAction) -> String? {
        groupsById[action.groupId]?.name
    }

    /// Mark an action resolved when the user opens it. Server triggers also
    /// auto-resolve in some cases (e.g. casting an appeal vote resolves the
    /// `appealVotePending` row), so this is mostly for "tapped" semantics.
    public func resolve(actionId: UUID) async {
        do {
            try await userActionRepo.resolve(actionId: actionId)
            actions.removeAll { $0.id == actionId }
        } catch {
            log.warning("resolve failed: \(error.localizedDescription)")
        }
    }
}
