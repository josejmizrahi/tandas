import Foundation
import Observation

/// R.2U.3 — store de jerarquía padre/hijo del contexto actual.
///
/// Vive per-context: cada `ContextDetailViewV2` crea el suyo con `@State` y lo
/// recarga al cambiar `context.id`. NO se promueve a long-lived: la jerarquía
/// depende del contexto activo y un cambio invalida todo.
///
/// Doctrina R.2U: la presencia de hijos/padres NO transfiere autoridad. La UI
/// usa este store sólo para navegación; los rights siguen viviendo en
/// `context_summary.my_permissions` / `available_actions` por instancia.
@MainActor
@Observable
public final class ContextHierarchyStore {
    public private(set) var parents: [ContextHierarchyNode] = []
    public private(set) var children: [ContextHierarchyNode] = []
    public private(set) var ancestors: [ContextHierarchyNode] = []
    public private(set) var tree: ContextTreeNode?
    public private(set) var phase: StorePhase = .idle
    public private(set) var treePhase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview helper: state hidratado sin llamar al backend.
    public init(
        rpc: any RuulRPCClient,
        previewParents: [ContextHierarchyNode],
        previewChildren: [ContextHierarchyNode],
        previewAncestors: [ContextHierarchyNode] = [],
        previewTree: ContextTreeNode? = nil
    ) {
        self.rpc = rpc
        self.parents = previewParents
        self.children = previewChildren
        self.ancestors = previewAncestors
        self.tree = previewTree
        self.phase = .loaded
        self.treePhase = previewTree == nil ? .idle : .loaded
    }

    /// Carga parents + children + ancestors en paralelo. Para árbol completo
    /// usar `loadTree(rootContextId:)` aparte (más caro).
    public func load(contextId: UUID) async {
        phase = .loading
        do {
            async let parentsT = rpc.contextParents(contextId: contextId)
            async let childrenT = rpc.contextChildren(contextId: contextId)
            async let ancestorsT = rpc.contextAncestors(contextId: contextId)
            let (p, c, a) = try await (parentsT, childrenT, ancestorsT)
            parents = p
            children = c
            ancestors = a
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Carga el árbol completo del contexto raíz dado. Se invoca sólo desde
    /// `ContextTreeView` (pantalla secundaria) porque es la consulta más cara.
    public func loadTree(rootContextId: UUID) async {
        treePhase = .loading
        do {
            tree = try await rpc.contextTree(rootContextId: rootContextId)
            treePhase = .loaded
        } catch {
            treePhase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func reset() {
        parents = []
        children = []
        ancestors = []
        tree = nil
        phase = .idle
        treePhase = .idle
    }
}
