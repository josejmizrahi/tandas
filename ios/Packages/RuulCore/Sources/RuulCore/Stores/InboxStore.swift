import Foundation
import Observation

/// D.21B — `@MainActor` store backing the in-app Inbox surface.
/// Holds the most recent N items + an unread count for badge use.
/// Optimistic mark-read with revert on failure.
@MainActor
@Observable
public final class InboxStore {
    public private(set) var phase: StorePhase = .idle
    public private(set) var items: [InboxItem] = []
    public private(set) var unreadCount: Int = 0
    public private(set) var errorMessage: String?

    private let repository: CanonicalInboxRepository
    private var loadedScope: UUID??  // double-optional: nil = never loaded, .some(nil) = all-groups, .some(uuid) = group-scoped

    public init(repository: CanonicalInboxRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var unreadItems: [InboxItem] {
        items.filter { !$0.isRead }
    }

    public var readItems: [InboxItem] {
        items.filter { $0.isRead }
    }

    // MARK: - Intents

    public func refresh(groupId: UUID? = nil) async {
        if items.isEmpty || loadedScope != .some(groupId) {
            phase = .loading
        }
        do {
            async let listFetch = repository.list(groupId: groupId, unreadOnly: false, limit: 100)
            async let countFetch = repository.unreadCount(groupId: groupId)
            let fetched = try await listFetch
            let count = try await countFetch
            items = fetched
            unreadCount = count
            loadedScope = .some(groupId)
            phase = .loaded
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID? = nil) async {
        if loadedScope == .some(groupId), !items.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Optimistic. Sets `read_at = now()` locally, fires backend, reverts on failure.
    @discardableResult
    public func markRead(_ item: InboxItem) async -> Bool {
        guard !item.isRead else { return true }
        let now = Date()
        let optimistic = InboxItem(
            id: item.id,
            groupId: item.groupId,
            category: item.category,
            payload: item.payload,
            dispatchStatus: item.dispatchStatus,
            dispatchedAt: item.dispatchedAt,
            readAt: now,
            createdAt: item.createdAt
        )
        replace(item, with: optimistic)
        unreadCount = max(0, unreadCount - 1)
        do {
            try await repository.markRead(outboxId: item.id)
            return true
        } catch {
            // Revert.
            replace(optimistic, with: item)
            unreadCount += 1
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func markAllRead(groupId: UUID? = nil) async -> Bool {
        let snapshot = items
        let now = Date()
        items = items.map { row in
            (groupId == nil || row.groupId == groupId) && !row.isRead
                ? InboxItem(
                    id: row.id,
                    groupId: row.groupId,
                    category: row.category,
                    payload: row.payload,
                    dispatchStatus: row.dispatchStatus,
                    dispatchedAt: row.dispatchedAt,
                    readAt: now,
                    createdAt: row.createdAt
                )
                : row
        }
        let previousCount = unreadCount
        unreadCount = items.filter { !$0.isRead }.count
        do {
            _ = try await repository.markAllRead(groupId: groupId)
            return true
        } catch {
            items = snapshot
            unreadCount = previousCount
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func refreshBadge(groupId: UUID? = nil) async {
        do {
            unreadCount = try await repository.unreadCount(groupId: groupId)
        } catch {
            // Silent — badge is non-critical.
        }
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Internals

    private func replace(_ old: InboxItem, with new: InboxItem) {
        guard let idx = items.firstIndex(where: { $0.id == old.id }) else { return }
        items[idx] = new
    }
}
