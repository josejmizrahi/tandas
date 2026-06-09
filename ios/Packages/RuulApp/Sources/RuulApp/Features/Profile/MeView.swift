import SwiftUI
import RuulCore

/// F.NAV.6 — Tab "Yo" consolidado. Reemplaza el placeholder con perfil real:
/// Mi actividad / Mis contextos / Mis suscripciones / Mi red de confianza /
/// Configuración / Cerrar sesión.
///
/// "Mis recursos" queda como placeholder hasta que exista un aggregator
/// cross-context (today resources live within contexts; MyWorld previo fue
/// deprecado en F.NAV).
public struct MeView: View {
    let container: DependencyContainer
    /// F.NAV.6 — jump al tab Contextos desde la sección "Mis contextos".
    let goToContexts: () -> Void

    @State private var isShowingSettings = false

    public init(container: DependencyContainer, goToContexts: @escaping () -> Void) {
        self.container = container
        self.goToContexts = goToContexts
    }

    public var body: some View {
        NavigationStack {
            List {
                headerSection
                myStuffSection
                trustSection
                settingsSection
                signOutSection
            }
            .navigationTitle("Yo")
            .sheet(isPresented: $isShowingSettings) {
                PersonalSettingsView(container: container)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                ActorInitialsView(
                    name: container.currentActorStore.actor?.displayName ?? "—",
                    size: 56
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(container.currentActorStore.actor?.displayName ?? "—")
                        .font(.title3.weight(.semibold))
                    Text("Tu cuenta")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Mis cosas

    @ViewBuilder
    private var myStuffSection: some View {
        Section {
            NavigationLink {
                MyActivityFeedView(container: container)
            } label: {
                Label("Mi actividad", systemImage: "antenna.radiowaves.left.and.right")
            }
            // R.5V.Calendar 2026-06-09 — Mi calendario cross-context (events
            // + reservaciones donde participo en todos mis contextos).
            NavigationLink {
                MyCalendarView(container: container)
            } label: {
                Label("Mi calendario", systemImage: "calendar")
            }
            Button {
                goToContexts()
            } label: {
                HStack {
                    Label("Mis contextos", systemImage: "square.grid.2x2.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            NavigationLink {
                MySubscriptionsView(container: container)
            } label: {
                Label("Mis suscripciones", systemImage: "bookmark.fill")
            }
            NavigationLink {
                MyResourcesView(container: container)
            } label: {
                Label("Mis recursos", systemImage: "shippingbox.fill")
            }
        } header: {
            Text("Mis cosas")
        }
    }

    // MARK: - Confianza

    @ViewBuilder
    private var trustSection: some View {
        Section {
            NavigationLink {
                MyTrustNetworkView(container: container)
            } label: {
                Label("Mi red de confianza", systemImage: "person.line.dotted.person")
            }
        }
    }

    // MARK: - Configuración

    @ViewBuilder
    private var settingsSection: some View {
        Section {
            Button {
                isShowingSettings = true
            } label: {
                HStack {
                    Label("Configuración", systemImage: "gearshape")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Cerrar sesión

    @ViewBuilder
    private var signOutSection: some View {
        Section {
            Button {
                Task { await container.signOut() }
            } label: {
                Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview("Me (demo)") {
    MeView(container: .demo(), goToContexts: {})
}
