import SwiftUI
import RuulCore

/// F.NAV — Shell global con 5 tabs (PRODUCTION post-F.NAV.7).
///
/// Doctrina F.NAV (`Plans/Doctrine/FNAV_AppShellNavigation.md`):
/// Home / Contextos / Crear / Actividad / Yo. ContextHome vive dentro de la
/// tab Contextos como destination push de `ContextsListView`. El switcher es
/// sheet (F.NAV.4). El tab Crear no tiene contenido propio — auto-bounce a
/// `CreateIntentSheet` (F.NAV.5).
public struct MainTabShell: View {
    let container: DependencyContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var previousTab: AppTab = .home
    @State private var isShowingCreateSheet = false
    @State private var isShowingJoinByCode = false
    @State private var prefilledInviteCode: String?
    /// R.5Y.A3 — Destination resuelto por `AttentionDispatcher` cuando el usuario
    /// tapea el `tabViewBottomAccessory`. Sheet único globalmente; cualquier kind
    /// presente o futuro (incluye R.6 rule_violation vía `.unsupported`).
    @State private var presentedAttention: AttentionDestination?
    /// NavigationStack path del tab Contextos, levantado al shell para que
    /// `jumpToContext` desde Home/atención pueda empujar directo al
    /// ContextHome del target en vez de dejar al usuario en la lista.
    @State private var contextsPath: [AppContext] = []

    public init(container: DependencyContainer) {
        self.container = container
    }

    /// Cambia al tab Contextos y empuja el ContextHome del target.
    /// Llamado desde Home (tarjetas Continuar, attention items).
    ///
    /// Doctrina de orden:
    ///   1. Switch de tab PRIMERO, para que SwiftUI commitee la transición
    ///      y el NavigationStack del tab Contextos esté visible antes de
    ///      mutar su path (si pusheas con el tab oculto, la barra/contenido
    ///      no propagan al revelarse).
    ///   2. Si el target ya está al tope del stack (mismo contexto al que
    ///      el usuario estaba antes de irse a Home), NO toques el path —
    ///      el switch de tab basta para revelar la vista existente.
    ///   3. Si es un contexto distinto, primero pop a `[]` y luego push
    ///      en el siguiente runloop para forzar a SwiftUI a desmontar el
    ///      destination anterior antes de montar el nuevo. Reemplazar
    ///      `[A]` por `[B]` en un solo tick deja al NavigationStack en
    ///      un estado inconsistente (toolbar vacío + descriptor stale).
    private func jumpToContext(_ context: AppContext) {
        container.contextStore.switchTo(context)
        selectedTab = .contexts
        if contextsPath.last?.id != context.id {
            DispatchQueue.main.async {
                contextsPath = []
                DispatchQueue.main.async {
                    contextsPath = [context]
                }
            }
        }
        Task { await container.contextPreferencesStore.recordVisit(context.id) }
    }

    /// F.NAV.7 fix: Binding proxy intercepta la selección del tab antes de
    /// mutar el state. Si el usuario tapea `.create`, abrimos la sheet y NO
    /// movemos el selectedTab (que se quedará en el tab previo). Esto evita
    /// los crashes esporádicos del patrón onChange.
    private var tabBinding: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .create {
                    isShowingCreateSheet = true
                } else {
                    previousTab = selectedTab
                    selectedTab = newValue
                }
            }
        )
    }

    public var body: some View {
        TabView(selection: tabBinding) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(
                    container: container,
                    jumpToContext: jumpToContext,
                    onTriggerCreate: { isShowingCreateSheet = true }
                )
            }

            Tab("Espacios", systemImage: "square.grid.2x2.fill", value: AppTab.contexts) {
                // ContextsListView trae su propio NavigationStack con path bindeado.
                ContextsListView(container: container, path: $contextsPath)
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
                        // R.4D (P1.1) — centro de notificaciones con badge de
                        // no-leídas en el toolbar de la tab Actividad.
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink {
                                    NotificationCenterView(container: container)
                                } label: {
                                    Image(systemName: container.notificationsStore.unreadCount > 0
                                          ? "bell.badge.fill" : "bell")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.red, Color.accentColor)
                                        .accessibilityLabel(
                                            container.notificationsStore.unreadCount > 0
                                            ? "Notificaciones, \(container.notificationsStore.unreadCount) sin leer"
                                            : "Notificaciones"
                                        )
                                }
                            }
                        }
                        .task { await container.notificationsStore.load() }
                }
            }

            Tab("Yo", systemImage: "person.crop.circle.fill", value: AppTab.me) {
                MeView(container: container, goToContexts: { selectedTab = .contexts })
            }
        }
        // R.5Y.A3 — Attention Center cross-context pegado sobre el tab bar.
        // Liquid Glass nativo. Cuando el inbox está vacío, el ViewBuilder
        // colapsa a EmptyView y el accessory desaparece (iOS 26.0 baseline).
        .tabViewBottomAccessory {
            if let top = container.attentionInboxStore.topPriorityItem {
                AttentionBottomAccessoryView(
                    item: top,
                    totalCount: container.attentionInboxStore.items.count,
                    onTap: { presentedAttention = AttentionDispatcher.destination(for: top) }
                )
            }
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateIntentSheet(container: container)
        }
        .sheet(isPresented: $isShowingJoinByCode, onDismiss: { prefilledInviteCode = nil }) {
            JoinByCodeView(container: container, prefilledCode: prefilledInviteCode)
        }
        .sheet(item: $presentedAttention) { destination in
            AttentionDestinationSheet(destination: destination, container: container)
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

#Preview("Tab Shell (demo)") {
    MainTabShell(container: .demo())
}
