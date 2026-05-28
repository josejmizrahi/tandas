import Foundation
import Observation

/// `@MainActor` store for Primitiva 13 (Memoria). Holds the most
/// recent system events for the current group + a paginate-older
/// affordance. Foundation V1 keeps it intentionally simple:
/// refresh = newest 100; loadMore = append the next page using the
/// oldest known event's timestamp as cursor.
@MainActor
@Observable
public final class EventsStore {
    public private(set) var events: [GroupEvent] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?
    public private(set) var isLoadingMore: Bool = false
    public private(set) var reachedEnd: Bool = false

    private let repository: CanonicalEventsRepository
    private var loadedGroupId: UUID?
    private let pageSize: Int = 100

    // V2-A1 — realtime listener handle for the active group's
    // `group_events` stream. `startListening` is idempotent: a second
    // call with the same group_id is a no-op; a call with a different
    // group_id swaps the subscription.
    private var realtimeSubscription: (any GroupRealtimeSubscription)?
    private var realtimeGroupId: UUID?

    public init(repository: CanonicalEventsRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var isEmpty: Bool { events.isEmpty }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if events.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.recentEvents(groupId: groupId, limit: pageSize, before: nil)
            events = fetched
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
            reachedEnd = fetched.count < pageSize
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !events.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Append the next page of older events using the oldest currently
    /// known event's `occurredAt` as cursor. No-op once `reachedEnd`.
    public func loadMore(groupId: UUID) async {
        guard !isLoadingMore, !reachedEnd else { return }
        guard let cursor = events.last?.occurredAt else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await repository.recentEvents(
                groupId: groupId, limit: pageSize, before: cursor
            )
            events.append(contentsOf: next)
            reachedEnd = next.count < pageSize
        } catch {
            errorMessage = UserFacingError.from(error).message
        }
    }

    public func clear() {
        events = []
        phase = .idle
        loadedGroupId = nil
        errorMessage = nil
        reachedEnd = false
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Realtime (V2-A1)

    public func startListening(groupId: UUID, realtime: any GroupRealtimeService) async {
        if realtimeGroupId == groupId, realtimeSubscription != nil { return }
        await stopListening()
        realtimeGroupId = groupId
        realtimeSubscription = await realtime.subscribe(
            groupId: groupId,
            table: .events,
            onChange: { [weak self] in
                await self?.refresh(groupId: groupId)
            }
        )
    }

    public func stopListening() async {
        guard let sub = realtimeSubscription else { return }
        realtimeSubscription = nil
        realtimeGroupId = nil
        await sub.cancel()
    }
}
