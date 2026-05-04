import Foundation
import OSLog

@Observable @MainActor
final class InboxCoordinator {
    private(set) var actions: [UserAction] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    private let userId: UUID
    private let groupId: UUID?
    private let userActionRepo: any UserActionRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "inbox")

    init(userId: UUID, groupId: UUID?, userActionRepo: any UserActionRepository) {
        self.userId = userId
        self.groupId = groupId
        self.userActionRepo = userActionRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            actions = try await userActionRepo.pending(userId: userId, groupId: groupId)
        } catch {
            log.warning("inbox load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
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
