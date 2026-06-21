import SwiftUI
import RuulCore

/// R.2U.3 — vista del árbol completo del contexto raíz dado. Sólo estructura
/// (nombres + tipos). NO muestra members/roles/rights — esos viven en
/// `ContextDetailViewV2` de cada nodo.
///
/// Tap en un nodo accesible → `contextStore.switchTo` y pop. Subárboles
/// restringidos (`restricted=true`) se renderizan inertes.
public struct ContextTreeView: View {
    let rootContext: AppContext
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var store: ContextHierarchyStore

    public init(rootContext: AppContext, container: DependencyContainer) {
        self.rootContext = rootContext
        self.container = container
        _store = State(initialValue: ContextHierarchyStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.treePhase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.loadTree(rootContextId: rootContext.id) }
                }
            case .loaded:
                if let tree = store.tree {
                    treeList(tree)
                } else {
                    Text("Sin estructura").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Estructura")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadTree(rootContextId: rootContext.id)
        }
    }

    @ViewBuilder
    private func treeList(_ tree: ContextTreeNode) -> some View {
        let rows = Self.flatten(tree, depth: 0)
        List {
            Section {
                ForEach(rows, id: \.node.id) { row in
                    TreeNodeRow(
                        node: row.node,
                        depth: row.depth,
                        contextStore: container.contextStore,
                        onTap: { context in
                            container.contextStore.switchTo(context)
                            dismiss()
                        }
                    )
                }
            } footer: {
                // 7.C.5 — copy sin "doctrina R.2U" técnico.
                Text("Toca un espacio para entrar. Los espacios bloqueados necesitan invitación aparte — ver la estructura no te da acceso automático.")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// DFS pre-orden: aplana el árbol a `[(node, depth)]` para evitar
    /// recursión de SwiftUI dentro de `body` (que no puede inferir tipos
    /// opacos auto-referenciales).
    private static func flatten(_ node: ContextTreeNode, depth: Int) -> [(node: ContextTreeNode, depth: Int)] {
        var result: [(node: ContextTreeNode, depth: Int)] = [(node, depth)]
        if let children = node.children {
            for child in children {
                result.append(contentsOf: flatten(child, depth: depth + 1))
            }
        }
        return result
    }
}

private struct TreeNodeRow: View {
    let node: ContextTreeNode
    let depth: Int
    let contextStore: ContextStore
    let onTap: (AppContext) -> Void

    var body: some View {
        let available = contextStore.availableContexts.first(where: { $0.id == node.id })
        let isRoot = depth == 0
        HStack(spacing: 8) {
            if depth > 0 {
                Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
            }
            if isRoot {
                Image(systemName: symbolName(for: node))
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: symbolName(for: node))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.callout.weight(isRoot ? .semibold : .regular))
                    .foregroundStyle(node.restricted ? Color.secondary : Color.primary)
                Text(subtypeLabel(node.actorSubtype))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if node.restricted {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if available != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !node.restricted, let target = available else { return }
            onTap(target)
        }
    }

    private func symbolName(for node: ContextTreeNode) -> String {
        AppContext(id: node.id, kind: node.actorKind, subtype: node.actorSubtype, displayName: node.name)
            .symbolName
    }

    private func subtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family": return "Familia"
        case "community": return "Comunidad"
        case "project": return "Proyecto"
        case "trip": return "Viaje"
        case "friend_group": return "Grupo"
        case "company": return "Negocio"
        case "trust": return "Fideicomiso"
        default: return subtype
        }
    }
}

#Preview("Tree — Familia Mizrahi") {
    NavigationStack {
        ContextTreeView(
            rootContext: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                membershipType: "founder",
                memberCount: 3,
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
