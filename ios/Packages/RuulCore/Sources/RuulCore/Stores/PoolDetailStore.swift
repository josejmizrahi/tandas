import Foundation
import Observation

/// R.8.E/F — store del detalle de un pool: `pool_account_detail` +
/// (cuando `pool.resolve` está disponible) `preview_pool_resolution`.
/// Escrituras SOLO vía `contribute_to_pool` / `resolve_pool`.
@MainActor
@Observable
public final class PoolDetailStore {
    public private(set) var detail: PoolAccountDetail?
    /// R.8.C — preview de la resolución. Solo se carga cuando el backend
    /// ofrece `pool.resolve` habilitada; si el RPC del preview falla NO
    /// tira el detalle (queda `nil` y la UI omite el desglose).
    public private(set) var resolutionPreview: PoolResolutionPreview?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(
        rpc: any RuulRPCClient,
        previewDetail: PoolAccountDetail,
        resolutionPreview: PoolResolutionPreview? = nil
    ) {
        self.rpc = rpc
        self.detail = previewDetail
        self.resolutionPreview = resolutionPreview
        self.phase = .loaded
    }

    public func load(poolAccountId: UUID) async {
        if detail == nil { phase = .loading }
        do {
            let loaded = try await rpc.poolAccountDetail(poolAccountId: poolAccountId)
            detail = loaded
            if loaded.availableActions.can("pool.resolve") {
                resolutionPreview = try? await rpc.previewPoolResolution(poolAccountId: poolAccountId)
            } else {
                resolutionPreview = nil
            }
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    // MARK: - Acciones

    @discardableResult
    public func contribute(_ input: ContributeToPoolInput) async throws -> PoolContributionResult {
        let result = try await rpc.contributeToPool(input)
        await load(poolAccountId: input.poolAccountId)
        return result
    }

    @discardableResult
    public func resolve(poolAccountId: UUID, resolution: JSONValue?, clientId: String?) async throws -> PoolResolutionResult {
        let result = try await rpc.resolvePool(
            poolAccountId: poolAccountId,
            resolution: resolution,
            clientId: clientId
        )
        await load(poolAccountId: poolAccountId)
        return result
    }
}
