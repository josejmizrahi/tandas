import Foundation
import Observation

/// R.3A — store del feed personalizado del actor actual.
/// Fuente: `activity_feed(p_actor_id?, p_limit?)`.
@MainActor
@Observable
public final class ActivityFeedStore {
    public private(set) var items: [FeedItem] = []
    public private(set) var phase: StorePhase = .idle
    /// FE.6 — paginación por offset (el feed es un digest rankeado).
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false

    private let rpc: any RuulRPCClient
    private let pageSize: Int

    public init(rpc: any RuulRPCClient, pageSize: Int = 50) {
        self.rpc = rpc
        self.pageSize = pageSize
    }

    public init(rpc: any RuulRPCClient, previewItems: [FeedItem]) {
        self.rpc = rpc
        self.pageSize = 50
        self.items = previewItems
        self.phase = .loaded
    }

    public func load() async {
        if items.isEmpty { phase = .loading }
        do {
            let feed = try await rpc.activityFeed(actorId: nil, limit: pageSize, offset: 0)
            items = feed.items
            hasMore = feed.items.count == pageSize
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// FE.6 — siguiente página; dedup defensivo por id (el ranking puede
    /// moverse entre llamadas si entró actividad nueva).
    public func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let feed = try await rpc.activityFeed(actorId: nil, limit: pageSize, offset: items.count)
            let known = Set(items.map(\.id))
            items.append(contentsOf: feed.items.filter { !known.contains($0.id) })
            hasMore = feed.items.count == pageSize
        } catch {
            hasMore = false
        }
    }

    public func reload() async {
        phase = .loading
        await load()
    }
}
