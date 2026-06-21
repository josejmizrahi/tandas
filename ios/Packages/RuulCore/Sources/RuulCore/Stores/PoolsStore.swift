import Foundation
import Observation

/// R.8.E — store de fondos (pools) de un contexto. Lecturas vía
/// `list_context_pools`; escrituras SOLO vía `create_pool`.
@MainActor
@Observable
public final class PoolsStore {
    public private(set) var pools: [PoolAccount] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewPools: [PoolAccount]) {
        self.rpc = rpc
        self.pools = previewPools
        self.phase = .loaded
    }

    public func load(context: AppContext) async {
        if pools.isEmpty { phase = .loading }
        do {
            pools = try await rpc.listContextPools(contextId: context.id)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    // MARK: - Acciones

    @discardableResult
    public func createPool(_ input: CreatePoolInput, context: AppContext) async throws -> PoolCreated {
        let result = try await rpc.createPool(input)
        await load(context: context)
        return result
    }

    /// 2026-06-21 — quick contribute desde la lista de botes (P0 #6 friend-group
    /// launch). Antes el usuario tenía que abrir cada bote para aportar; ahora
    /// puede hacerlo en 2 taps desde la lista. Recarga la lista para que el
    /// total se actualice inmediatamente.
    @discardableResult
    public func contribute(_ input: ContributeToPoolInput, context: AppContext) async throws -> PoolContributionResult {
        let result = try await rpc.contributeToPool(input)
        await load(context: context)
        return result
    }
}
