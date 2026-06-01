import Foundation

/// D.22 — Repository wrapping the unified `global_search` RPC.
/// One round-trip across 4 entity types for the active group.
public struct CanonicalSearchRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func search(
        groupId: UUID,
        query: String,
        limit: Int = 25
    ) async throws -> [SearchResult] {
        try await rpc.globalSearch(
            GlobalSearchParams(groupId: groupId, query: query, limit: limit)
        )
    }
}
