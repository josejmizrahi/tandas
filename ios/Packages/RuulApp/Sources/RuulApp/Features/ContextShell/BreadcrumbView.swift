import SwiftUI
import RuulCore

/// R.2U.3 — breadcrumb horizontal del contexto actual.
/// Muestra ancestros raíz → actual; tap en cualquier segmento accesible
/// cambia el contexto vía `ContextStore.switchTo`. Si el ancestor no está
/// entre los `availableContexts` del switcher (no eres miembro), se renderiza
/// como label inerte — la doctrina R.2U dice que ver el path no transfiere
/// acceso al contenido.
public struct BreadcrumbView: View {
    let context: AppContext
    let ancestors: [ContextHierarchyNode]
    let contextStore: ContextStore

    public init(
        context: AppContext,
        ancestors: [ContextHierarchyNode],
        contextStore: ContextStore
    ) {
        self.context = context
        self.ancestors = ancestors
        self.contextStore = contextStore
    }

    public var body: some View {
        // Ordenar de raíz → padre directo (depth descendente: la raíz tiene mayor depth).
        let chain = ancestors.sorted { ($0.depth ?? 0) > ($1.depth ?? 0) }

        if chain.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chain) { ancestor in
                        breadcrumbSegment(ancestor: ancestor)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(context.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .background(Theme.Surface.secondaryBackground)
        }
    }

    @ViewBuilder
    private func breadcrumbSegment(ancestor: ContextHierarchyNode) -> some View {
        if let available = contextStore.availableContexts.first(where: { $0.id == ancestor.id }) {
            Button {
                contextStore.switchTo(available)
            } label: {
                Text(ancestor.name)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            // Ancestor existente en backend pero el caller no es miembro:
            // no se permite navegar. Render inerte.
            Text(ancestor.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview("Breadcrumb — 2 niveles") {
    let container = DependencyContainer.demo()
    return VStack(spacing: 0) {
        BreadcrumbView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.fideicomiso,
                kind: .legalEntity,
                subtype: "trust",
                displayName: "Fideicomiso Nave Industrial"
            ),
            ancestors: [
                ContextHierarchyNode(
                    id: MockRuulRPCClient.DemoIds.familia,
                    name: "Familia Mizrahi",
                    actorKind: .collective,
                    actorSubtype: "family",
                    depth: 2
                ),
                ContextHierarchyNode(
                    id: MockRuulRPCClient.DemoIds.proyectoNave,
                    name: "Proyecto Nave Industrial",
                    actorKind: .collective,
                    actorSubtype: "project",
                    depth: 1
                )
            ],
            contextStore: container.contextStore
        )
        Spacer()
    }
}

#Preview("Breadcrumb — sin padres") {
    let container = DependencyContainer.demo()
    return VStack(spacing: 0) {
        BreadcrumbView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi"
            ),
            ancestors: [],
            contextStore: container.contextStore
        )
        Text("Sin padres → no se renderiza arriba")
            .font(.caption)
            .foregroundStyle(.secondary)
        Spacer()
    }
}
