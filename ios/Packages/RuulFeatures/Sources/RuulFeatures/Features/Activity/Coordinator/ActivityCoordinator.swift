import Foundation
import Observation
import OSLog
import RuulCore
import RuulUI

/// Loads + paginates `SystemEvent`s for `ActivityView`. Holds the
/// active filter state; refilters by re-querying (no client-side
/// filtering — server does it).
@Observable
@MainActor
public final class ActivityCoordinator {
    public let groupId: UUID
    private let repo: any SystemEventRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "history")

    private static let pageSize = 50

    public var filter: SystemEventFilter
    public var events: [SystemEvent] = []
    public var isLoading: Bool = false
    public var hasMore: Bool = true
    public var error: CoordinatorError?

    public init(groupId: UUID, repo: any SystemEventRepository) {
        self.groupId = groupId
        self.repo = repo
        self.filter = SystemEventFilter(groupId: groupId)
    }

    public func refresh() async {
        events = []
        hasMore = true
        error = nil
        await loadMore()
    }

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repo.query(filter: filter, limit: Self.pageSize, offset: events.count)
            events.append(contentsOf: page)
            if page.count < Self.pageSize { hasMore = false }
        } catch {
            log.error("loadMore failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar la historia")
        }
    }

    public func clearError() { error = nil }

    public func setEventType(_ type: SystemEventType?) {
        filter.eventType = type
        Task { await refresh() }
    }

    public func setMember(_ memberId: UUID?) {
        filter.memberId = memberId
        Task { await refresh() }
    }

    public func setDateRange(from: Date?, to: Date?) {
        filter.fromDate = from
        filter.toDate = to
        Task { await refresh() }
    }

    public func clearFilters() {
        filter = SystemEventFilter(groupId: groupId)
        Task { await refresh() }
    }

    public var hasAnyFilter: Bool {
        filter.memberId != nil || filter.eventType != nil ||
        filter.resourceId != nil || filter.fromDate != nil || filter.toDate != nil
    }
}
