import Foundation
import Observation

/// R.2M / R.2S — store del `resource_type_catalog()`. Cachea el catálogo
/// global (lazy) para que `CreateResourceView` y la UI dinámica puedan
/// renderizar por backend sin hardcodear `ResourceType.allCases`.
@MainActor
@Observable
public final class ResourceTypeCatalogStore {
    public private(set) var catalog: ResourceTypeCatalog?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewCatalog: ResourceTypeCatalog) {
        self.rpc = rpc
        self.catalog = previewCatalog
        self.phase = .loaded
    }

    /// Hidrata el catálogo (no-op si ya está). Idempotente.
    public func loadIfNeeded() async {
        if catalog != nil { return }
        if phase.isLoading { return }
        phase = .loading
        do {
            catalog = try await rpc.resourceTypeCatalog()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func entries() -> [ResourceTypeCatalogEntry] {
        catalog?.entries ?? []
    }

    public func entry(for typeKey: String) -> ResourceTypeCatalogEntry? {
        catalog?.entry(for: typeKey)
    }

    public func reset() {
        catalog = nil
        phase = .idle
    }
}
