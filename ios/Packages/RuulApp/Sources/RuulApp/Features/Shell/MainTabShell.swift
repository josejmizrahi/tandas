import SwiftUI
import RuulCore

/// F.NAV.1+ — Shell global con 5 tabs.
///
/// Doctrina F.NAV (Plans/Doctrine/FNAV_AppShellNavigation.md):
/// Home / Contextos / Crear / Actividad / Yo. ContextHome ya no es la raíz;
/// vive dentro de la tab Contextos como destination push. F.NAV.3 sustituyó
/// el ContextShell preexistente por `ContextsListView` con NavigationStack
/// propia. El switcher pasa a sheet (F.NAV.4 lo enchufa).
public struct MainTabShell: View {
    let container: DependencyContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var previousTab: AppTab = .home
    @State private var isShowingCreateSheet = false
    @State private var isShowingJoinByCode = false
    @State private var prefilledInviteCode: String?

    public init(container: DependencyContainer) {
        self.container = container
    }

    /// F.NAV.2 — Cambia al tab Contextos y switchea el ContextStore al
    /// contexto pedido. Llamado desde Home cuando el usuario tapea un item
    /// de "Continuar" o un conflicto de reservación.
    private func jumpToContext(_ context: AppContext) {
        container.contextStore.switchTo(context)
        selectedTab = .contexts
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(container: container, jumpToContext: jumpToContext)
            }

            Tab("Contextos", systemImage: "square.grid.2x2.fill", value: AppTab.contexts) {
                // ContextsListView trae su propio NavigationStack con path bindeado.
                ContextsListView(container: container)
            }

            Tab("Crear", systemImage: "plus.circle.fill", value: AppTab.create, role: nil) {
                // F.NAV.5 — el tab Crear no tiene contenido propio. Al
                // seleccionarlo abrimos la sheet intent-first y volvemos al
                // tab anterior (patrón Twitter/Instagram).
                Color.clear
            }

            Tab("Actividad", systemImage: "bell.fill", value: AppTab.activity) {
                NavigationStack {
                    MyActivityFeedView(container: container)
                        .navigationTitle("Actividad")
                }
            }

            Tab("Yo", systemImage: "person.crop.circle.fill", value: AppTab.me) {
                MeTabPlaceholderView(container: container)
            }
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateIntentSheet(container: container)
        }
        // F.NAV.5 — auto-bounce: tap al tab Crear dispara la sheet y vuelve
        // al tab previo. Si el usuario re-tapea Crear estando ya allí, la
        // sheet vuelve a aparecer.
        .onChange(of: selectedTab) { oldTab, newTab in
            if newTab == .create {
                isShowingCreateSheet = true
                selectedTab = oldTab == .create ? previousTab : oldTab
            } else {
                previousTab = newTab
            }
        }
        .sheet(isPresented: $isShowingJoinByCode, onDismiss: { prefilledInviteCode = nil }) {
            JoinByCodeView(container: container, prefilledCode: prefilledInviteCode)
        }
        // F.NAV.1 — refrescar contextos + invitaciones al regresar del background.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await container.contextStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await container.contextPreferencesStore.load()
                await container.attentionInboxStore.load()
            }
        }
        // F.NAV.1 — universal links / ruul:// abren JoinByCode globalmente.
        .onChange(of: container.deepLinks.pendingInviteCode, initial: true) { _, code in
            guard code != nil else { return }
            prefilledInviteCode = container.deepLinks.consumePendingInviteCode()
            isShowingJoinByCode = true
        }
    }
}

/// F.NAV.1 — enum identifier para las 5 tabs.
public enum AppTab: Hashable {
    case home, contexts, create, activity, me
}

// MARK: - Stubs F.NAV.1

/// F.NAV.6 reemplaza con la pantalla de perfil consolidada
/// (mi actividad / mis contextos / mis recursos / mis suscripciones / mi red
/// de confianza / configuración). F.NAV.1 stub: navega a PersonalSettingsView.
private struct MeTabPlaceholderView: View {
    let container: DependencyContainer
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        ActorInitialsView(
                            name: container.currentActorStore.actor?.displayName ?? "—",
                            size: 56
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(container.currentActorStore.actor?.displayName ?? "—")
                                .font(.title3.weight(.semibold))
                            Text("Tu perfil")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Configuración", systemImage: "gearshape")
                    }
                    Button {
                        Task { await container.signOut() }
                    } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Yo")
            .sheet(isPresented: $isShowingSettings) {
                PersonalSettingsView(container: container)
            }
        }
    }
}

#Preview("Tab Shell (demo)") {
    MainTabShell(container: .demo())
}
