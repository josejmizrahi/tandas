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
            // P1 fix 2026-06-08: usar CreateResourceFlow (Subtype Picker UX D shipped)
            // en vez del legacy CreateResourceView que tenía bugs en el path 10-arg.
            CreateResourceFlow(context: context, store: store, container: container)
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
                Section {
                    ForEach(store.personalResources) { resource in
                        NavigationLink {
                            ResourceDetailViewV2(resourceId: resource.resourceId, context: context, container: container)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.displayName)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(Theme.Text.primary)
                                    Text(resource.reasons.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                        .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName)
                                    .foregroundStyle(Theme.Tint.primary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var contextResourcesList: some View {
        if store.resources.isEmpty {
            List {
                reservationsEntry
                Section {
                    EmptyStateView(
                        symbolName: "shippingbox",
                        title: "Sin recursos",
                        message: "Registra una casa, un fondo común, un coche o cualquier cosa que este contexto gobierne."
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
        } else {
            List {
                reservationsEntry
                Section {
                    ForEach(store.resources) { resource in
                        NavigationLink {
                            ResourceDetailViewV2(resourceId: resource.resourceId, context: context, container: container)
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(resource.displayName)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(Theme.Text.primary)
                                        Text(rightsSummary(resource))
                                            .font(.caption)
                                            .foregroundStyle(Theme.Text.secondary)
                                            .lineLimit(1)
                                    }
                                } icon: {
                                    Image(systemName: resource.type.symbolName)
                                        .foregroundStyle(Theme.Tint.primary)
                                }
                                Spacer()
                                if let value = resource.estimatedValue {
                                    Text(value.currencyLabel(resource.currency))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Recursos (\(store.resources.count))")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// Acceso context-wide a `list_context_reservations`. Visible sólo para
    /// contextos governing (no para el personal, donde no se gobiernan recursos).
    @ViewBuilder
    private var reservationsEntry: some View {
        Section {
            NavigationLink {
                ContextReservationsView(context: context, container: container)
            } label: {
                Label("Reservaciones del contexto", systemImage: "calendar.badge.clock")
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
