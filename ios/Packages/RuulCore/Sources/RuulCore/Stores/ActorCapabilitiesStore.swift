import Foundation
import Observation

/// R.2S.1 — store de `actor_capabilities` + `actor_capabilities_catalog`.
/// Cachea el catálogo global (lazy) y las capabilities por actorId.
@MainActor
@Observable
public final class ActorCapabilitiesStore {
    public private(set) var catalog: ActorCapabilitiesCatalog?
    public private(set) var catalogPhase: StorePhase = .idle
    public private(set) var capabilitiesByActor: [UUID: ActorCapabilities] = [:]
    public private(set) var phaseByActor: [UUID: StorePhase] = [:]

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(
        rpc: any RuulRPCClient,
        previewCatalog: ActorCapabilitiesCatalog?,
        previewCapabilities: [UUID: ActorCapabilities] = [:]
    ) {
        self.rpc = rpc
        self.catalog = previewCatalog
        if previewCatalog != nil { catalogPhase = .loaded }
        self.capabilitiesByActor = previewCapabilities
        for id in previewCapabilities.keys { phaseByActor[id] = .loaded }
    }

    // MARK: - Carga

    /// Hidrata el catálogo (no-op si ya está). Idempotente.
    public func loadCatalogIfNeeded() async {
        if catalog != nil { return }
        if catalogPhase.isLoading { return }
        catalogPhase = .loading
        do {
            catalog = try await rpc.actorCapabilitiesCatalog()
            catalogPhase = .loaded
        } catch {
            catalogPhase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Hidrata las capabilities de un actor. Si ya está cacheado, no-op salvo `force`.
    public func loadCapabilities(actorId: UUID, force: Bool = false) async {
        if !force, capabilitiesByActor[actorId] != nil { return }
        if phaseByActor[actorId]?.isLoading == true { return }
        phaseByActor[actorId] = .loading
        do {
            let caps = try await rpc.actorCapabilities(actorId: actorId)
            capabilitiesByActor[actorId] = caps
            phaseByActor[actorId] = .loaded
        } catch {
            phaseByActor[actorId] = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func reset() {
        catalog = nil
        catalogPhase = .idle
        capabilitiesByActor.removeAll()
        phaseByActor.removeAll()
    }

    // MARK: - Consultas

    public func capabilities(for actorId: UUID) -> ActorCapabilities? {
        capabilitiesByActor[actorId]
    }

    public func has(actorId: UUID, capability: ActorCapabilityKey) -> Bool {
        capabilitiesByActor[actorId]?.has(capability) ?? false
    }

    public func has(actorId: UUID, capability: String) -> Bool {
        capabilitiesByActor[actorId]?.has(capability) ?? false
    }

    /// Subtypes del catálogo que poseen una capability.
    public func subtypes(with capability: ActorCapabilityKey) -> [String] {
        catalog?.subtypes(with: capability) ?? []
    }

    /// Capabilities que un subtype tiene según el catálogo.
    public func capabilities(forSubtype subtype: String) -> [String] {
        catalog?.capabilities(forSubtype: subtype) ?? []
    }

    public func displayName(for capabilityKey: String) -> String? {
        catalog?.displayName(for: capabilityKey)
    }
}
