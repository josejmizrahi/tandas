import Foundation
import Observation

/// F.6 — store de recursos del contexto. La visibilidad es rights-based:
/// el backend solo devuelve recursos que el caller puede ver.
@MainActor
@Observable
public final class ResourcesStore {
    public private(set) var resources: [ContextResource] = []
    /// Contexto personal: recursos que puedes ver vía `my_world()` (incluye los
    /// que ves a través de los colectivos a los que perteneces, no solo los que
    /// tienes en directo). Para contextos colectivos queda vacío.
    public private(set) var personalResources: [MyWorldResource] = []
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
        if resources.isEmpty && personalResources.isEmpty { phase = .loading }
        do {
            // El contexto personal lista lo mismo que `my_world()` muestra en el
            // home ("Recursos que puedes ver"): list_context_resources(actor_persona)
            // solo devolvería los recursos con un right directo de la persona, no
            // los que ve vía sus colectivos.
            if context.isPersonal {
                async let worldTask = rpc.myWorld()
                async let summaryTask = rpc.contextSummary(contextId: context.id)
                let (world, summary) = try await (worldTask, summaryTask)
                personalResources = world.resources
                resources = []
                myPermissions = summary.myPermissions
            } else {
                async let resourcesTask = rpc.listContextResources(contextId: context.id)
                async let summaryTask = rpc.contextSummary(contextId: context.id)
                let (loaded, summary) = try await (resourcesTask, summaryTask)
                resources = loaded
                personalResources = []
                myPermissions = summary.myPermissions
            }
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

// R.9.I — `ResourceDetailStore` (F.6, store de ResourceDetailView V1) fue
// eliminado junto con la vista: ResourceDetailViewV2 usa ResourceDescriptorStore.
