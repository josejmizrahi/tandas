import SwiftUI
import RuulCore

/// F.NAV.8 — Vista plana de recursos cross-context que el caller puede ver.
/// Carga `my_world()` (existente desde R.0F) que ya agrega `resources[]` con
/// reasons del backend ("USE", "GOVERN via Familia Mizrahi", etc.).
///
/// Sólo informativa por ahora: muestra los recursos y sus reasons. La
/// navegación a `ResourceDetailView` requiere un `AppContext` específico —
/// se resuelve al primer contexto disponible para que el back button no
/// quede colgado.
public struct MyResourcesView: View {
    let container: DependencyContainer

    @State private var world: MyWorld?
    @State private var phase: StorePhase = .idle
    @State private var selectedResource: NavigationTarget?

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                LoadingStateView()
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await load() }
                }
            case .loaded:
                if let world, world.resources.isEmpty {
                    ContentUnavailableView(
                        "Sin recursos",
                        systemImage: "shippingbox",
                        description: Text("Aún no tienes ni puedes ver recursos en tus contextos.")
                    )
                } else if let world {
                    List {
                        Section {
                            ForEach(world.resources) { r in
                                Button {
                                    openResource(r)
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.displayName)
                                                .font(.callout.weight(.medium))
                                                .foregroundStyle(Theme.Text.primary)
                                            if !r.reasons.isEmpty {
                                                Text(r.reasons.joined(separator: " · "))
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.Text.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: (ResourceType(rawValue: r.resourceType) ?? .other).symbolName)
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                }
                            }
                        } header: {
                            Text("\(world.resources.count) recurso\(world.resources.count == 1 ? "" : "s")")
                        } footer: {
                            Text("Recursos que puedes ver desde cualquiera de tus contextos.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("Mis recursos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selectedResource) { target in
            NavigationStack {
                // 2026-06-08 — MyResourcesView es cross-context; el contexto
                // resuelto en openResource() es un best-effort que puede no
                // coincidir con el contexto real del recurso. V2 valida más
                // estrictamente que v1 (RLS + sub-feature navigation por
                // contexto), causando errores de permisos cuando el atajo
                // falla. Hasta que my_world() devuelva el context_id real del
                // recurso, mantenemos v1 sólo en esta entrada.
                ResourceDetailView(
                    resourceId: target.resourceId,
                    context: target.context,
                    container: container
                )
            }
        }
    }

    private func load() async {
        if world == nil { phase = .loading }
        do {
            world = try await container.rpc.myWorld()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Resuelve `AppContext` para el resource detail. Defaultea al primer
    /// contexto colectivo disponible; si no hay ninguno, al personal.
    private func openResource(_ resource: MyWorldResource) {
        let collective = container.contextStore.availableContexts.first { !$0.isPersonal }
        let personal = container.contextStore.availableContexts.first { $0.isPersonal }
        guard let ctx = collective ?? personal else { return }
        selectedResource = NavigationTarget(resourceId: resource.resourceId, context: ctx)
    }

    struct NavigationTarget: Identifiable, Hashable {
        let resourceId: UUID
        let context: AppContext
        var id: UUID { resourceId }
    }
}

#Preview("Mis recursos (demo)") {
    NavigationStack {
        MyResourcesView(container: .demo())
    }
}
