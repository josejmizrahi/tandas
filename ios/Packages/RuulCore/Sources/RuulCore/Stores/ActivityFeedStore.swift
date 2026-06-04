import Foundation
import Observation

/// R.3A — store del feed personalizado del actor actual.
/// Fuente: `activity_feed(p_actor_id?, p_limit?)`.
@MainActor
@Observable
public final class ActivityFeedStore {
    public private(set) var items: [FeedItem] = []
    public private(set) var phase: StorePhase = .idle

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
            let feed = try await rpc.activityFeed(actorId: nil, limit: pageSize)
            items = feed.items
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func reload() async {
        phase = .loading
        await load()
    }
}
