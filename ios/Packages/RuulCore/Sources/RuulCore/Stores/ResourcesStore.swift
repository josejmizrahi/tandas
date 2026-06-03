import Foundation
import Observation

/// F.6 — store de recursos del contexto. La visibilidad es rights-based:
/// el backend solo devuelve recursos que el caller puede ver.
@MainActor
@Observable
public final class ResourcesStore {
    public private(set) var resources: [ContextResource] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewResources: [ContextResource], permissions: [String] = []) {
        self.rpc = rpc
        self.resources = previewResources
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public func load(context: AppContext) async {
        if resources.isEmpty { phase = .loading }
        do {
            async let resourcesTask = rpc.listContextResources(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (resourcesTask, summaryTask)
            resources = loaded
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func canCreate(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("resources.create")
    }

    public func canManage(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("resources.manage")
    }

    // MARK: - Mutaciones

    public func createResource(_ input: CreateResourceInput, context: AppContext) async throws -> Resource {
        let resource = try await rpc.createResource(input)
        await load(context: context)
        return resource
    }

    public func grantRight(_ input: GrantRightInput, context: AppContext) async throws {
        _ = try await rpc.grantRight(input)
        await load(context: context)
    }

    public func revokeRight(rightId: UUID, context: AppContext) async throws {
        try await rpc.revokeRight(rightId: rightId)
        await load(context: context)
    }

    public func archive(resourceId: UUID, context: AppContext) async throws {
        try await rpc.archiveResource(resourceId: resourceId)
        await load(context: context)
    }
}

/// F.6 — store del detalle de un recurso (recurso + derechos activos).
@MainActor
@Observable
public final class ResourceDetailStore {
    public private(set) var detail: ResourceDetail?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewDetail: ResourceDetail) {
        self.rpc = rpc
        self.detail = previewDetail
        self.phase = .loaded
    }

    public func load(resourceId: UUID) async {
        if detail == nil { phase = .loading }
        do {
            detail = try await rpc.resourceDetail(resourceId: resourceId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func grantRight(_ input: GrantRightInput) async throws {
        _ = try await rpc.grantRight(input)
        await load(resourceId: input.resourceId)
    }

    public func revokeRight(rightId: UUID, resourceId: UUID) async throws {
        try await rpc.revokeRight(rightId: rightId)
        await load(resourceId: resourceId)
    }
}
