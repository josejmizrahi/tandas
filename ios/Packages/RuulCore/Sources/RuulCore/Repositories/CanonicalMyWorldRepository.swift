import Foundation

/// R.0H.1 — repository for the My World view. Wraps the single
/// `my_world_summary()` RPC (R.0E.2) so stores/views can stay free of
/// RPC plumbing. Auth-scoped: the RPC resolves `auth.uid()` → actor
/// internally; no params required at this layer.
public struct CanonicalMyWorldRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Hydrate the full My World summary. R.0H.2 will consume this from
    /// `PersonalHomeView`; R.0H.1 keeps it backend-only.
    public func loadSummary() async throws -> MyWorldSummary {
        try await rpc.myWorldSummary()
    }
}
