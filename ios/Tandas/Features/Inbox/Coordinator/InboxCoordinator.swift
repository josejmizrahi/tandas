import Foundation
import OSLog

@Observable @MainActor
final class InboxCoordinator {
    private(set) var actions: [UserAction] = []
    private(set) var groupsById: [UUID: Group] = [:]
    private(set) var isLoading: Bool = false
    private(set) var error: CoordinatorError?

    private let userId: UUID
    /// When nil (default in 14.2), the inbox is cross-group: every pending
    /// UserAction for the user across every group they belong to. Pass an
    /// id to scope to a single group.
    private let groupId: UUID?
    private let userActionRepo: any UserActionRepository
    private let groupsRepo: (any GroupsRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "inbox")

    init(
        userId: UUID,
        groupId: UUID?,
        userActionRepo: any UserActionRepository,
        groupsRepo: (any GroupsRepository)? = nil
    ) {
        self.userId = userId
        self.groupId = groupId
        self.userActionRepo = userActionRepo
        self.groupsRepo = groupsRepo
    }

    func refresh() async {
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

    func clearError() { error = nil }

    func groupName(for action: UserAction) -> String? {
        groupsById[action.groupId]?.name
    }

    /// Mark an action resolved when the user opens it. Server triggers also
    /// auto-resolve in some cases (e.g. casting an appeal vote resolves the
    /// `appealVotePending` row), so this is mostly for "tapped" semantics.
    func resolve(actionId: UUID) async {
        do {
            try await userActionRepo.resolve(actionId: actionId)
            actions.removeAll { $0.id == actionId }
        } catch {
            log.warning("resolve failed: \(error.localizedDescription)")
        }
    }
}
