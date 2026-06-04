import SwiftUI
import RuulCore

/// F.6 — lista de recursos visibles del contexto.
public struct ResourcesListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourcesStore
    @State private var isShowingCreate = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ResourcesStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(context: context) }
                }

            case .loaded:
                resourcesList
            }
        }
        .navigationTitle("Recursos")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            if store.canCreate(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear recurso", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateResourceView(context: context, store: store, container: container)
        }
    }

    @ViewBuilder
    private var resourcesList: some View {
        if context.isPersonal {
            personalResourcesList
        } else {
            contextResourcesList
        }
    }

    /// Contexto personal: el mismo conjunto que el home ("Recursos que puedes ver"),
    /// con las razones de visibilidad como subtítulo.
    @ViewBuilder
    private var personalResourcesList: some View {
        if store.personalResources.isEmpty {
            EmptyStateView(
                symbolName: "shippingbox",
                title: "Sin recursos",
                message: "Nadie te ha compartido recursos todavía."
            )
        } else {
            List {
                ForEach(store.personalResources) { resource in
                    NavigationLink {
                        ResourceDetailView(resourceId: resource.resourceId, context: context, container: container)
                    } label: {
                        InfoRow(
                            symbolName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName,
                            title: resource.displayName,
                            subtitle: resource.reasons.joined(separator: " · ")
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contextResourcesList: some View {
        if store.resources.isEmpty {
            EmptyStateView(
                symbolName: "shippingbox",
                title: "Sin recursos",
                message: "Registra una casa, un fondo común, un coche o cualquier cosa que este contexto gobierne."
            )
        } else {
            List {
                ForEach(store.resources) { resource in
                    NavigationLink {
                        ResourceDetailView(resourceId: resource.resourceId, context: context, container: container)
                    } label: {
                        InfoRow(
                            symbolName: resource.type.symbolName,
                            title: resource.displayName,
                            subtitle: rightsSummary(resource),
                            value: resource.estimatedValue.map { $0.currencyLabel(resource.currency) }
                        )
                    }
                }
            }
        }
    }

    /// Resumen corto de quién tiene qué derecho.
    private func rightsSummary(_ resource: ContextResource) -> String {
        let kinds = Set(resource.rights.map(\.rightKind))
        return resource.type.label + (kinds.isEmpty ? "" : " · " + kinds.sorted().joined(separator: ", "))
    }
}

#Preview("Recursos") {
    NavigationStack {
        ResourcesListView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
