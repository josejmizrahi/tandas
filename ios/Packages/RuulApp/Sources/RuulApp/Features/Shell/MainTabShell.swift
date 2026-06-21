import SwiftUI
import RuulCore

/// Shell global de lanzamiento para grupos de amigos.
///
/// Navegación primaria: Inicio / Eventos / Dinero / Miembros / Ajustes.
/// Las primitivas avanzadas siguen existiendo, pero la superficie principal
/// opera sobre el grupo actual y optimiza los flujos diarios de amigos.
public struct MainTabShell: View {
    let container: DependencyContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var isShowingCreateSheet = false
    @State private var isShowingJoinByCode = false
    @State private var prefilledInviteCode: String?
    /// R.5Y.A3 — Destination resuelto por `AttentionDispatcher` cuando el usuario
    /// tapea el `tabViewBottomAccessory`. Sheet único globalmente; cualquier kind
    /// presente o futuro (incluye R.6 rule_violation vía `.unsupported`).
    @State private var presentedAttention: AttentionDestination?
    public init(container: DependencyContainer) {
        self.container = container
    }

    /// Home ahora cambia el grupo activo y lleva al centro operativo del grupo.
    private func jumpToContext(_ context: AppContext) {
        container.contextStore.switchTo(context)
        selectedTab = .events
        Task { await container.contextPreferencesStore.recordVisit(context.id) }
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Inicio", systemImage: "house.fill", value: AppTab.home) {
                HomeView(
                    container: container,
                    jumpToContext: jumpToContext,
                    onTriggerCreate: { isShowingCreateSheet = true },
                    onOpenSettings: { selectedTab = .settings }
                )
            }

            Tab("Eventos", systemImage: "calendar", value: AppTab.events) {
                CurrentGroupNavigation(
                    container: container,
                    emptyTitle: "Crea un grupo para programar eventos",
                    emptyMessage: "Invita a tus amigos y arma la próxima cena, viaje o noche de juegos.",
                    onCreateGroup: { isShowingCreateSheet = true },
                    onJoinGroup: { isShowingJoinByCode = true }
                ) { group in
                    EventsListView(context: group, container: container)
                }
            }

            Tab("Dinero", systemImage: "dollarsign.circle", value: AppTab.money) {
                CurrentGroupNavigation(
                    container: container,
                    emptyTitle: "Crea un grupo para llevar cuentas",
                    emptyMessage: "Registra gastos, botes, juegos y liquidaciones con tu grupo.",
                    onCreateGroup: { isShowingCreateSheet = true },
                    onJoinGroup: { isShowingJoinByCode = true }
                ) { group in
                    MoneyHomeView(context: group, container: container)
                }
            }

            Tab("Miembros", systemImage: "person.3", value: AppTab.members) {
                CurrentGroupNavigation(
                    container: container,
                    emptyTitle: "Crea un grupo para invitar amigos",
                    emptyMessage: "Los miembros, pendientes e invitados viven en un solo lugar.",
                    onCreateGroup: { isShowingCreateSheet = true },
                    onJoinGroup: { isShowingJoinByCode = true }
                ) { group in
                    MembersListView(context: group, container: container)
                }
            }

            Tab("Ajustes", systemImage: "gearshape", value: AppTab.settings) {
                LaunchSettingsView(
                    container: container,
                    onCreate: { isShowingCreateSheet = true },
                    onJoin: { isShowingJoinByCode = true }
                )
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
            CreateIntentSheet(container: container) { destination in
                presentedAttention = destination
            }
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

/// Enum identifier para las 5 tabs de lanzamiento.
public enum AppTab: Hashable {
    case home, events, money, members, settings
}

// MARK: - Current Group Wrappers

private struct CurrentGroupNavigation<Content: View>: View {
    let container: DependencyContainer
    let emptyTitle: String
    let emptyMessage: String
    let onCreateGroup: () -> Void
    let onJoinGroup: () -> Void
    @ViewBuilder let content: (AppContext) -> Content

    /// 2026-06-21 — switcher de grupo ubicuo en tabs Eventos/Dinero/Miembros.
    /// Antes el usuario quedaba "atrapado" en el grupo activo y sólo podía
    /// cambiarlo desde Inicio o Ajustes. Ahora el leading toolbar item muestra
    /// el grupo actual + chevron y abre `ContextSwitcherSheet`.
    @State private var isShowingSwitcher = false

    private var currentGroup: AppContext? {
        if let current = container.contextStore.currentContext, !current.isPersonal {
            return current
        }
        return container.contextStore.collectiveContexts.first
    }

    private var hasMultipleGroups: Bool {
        container.contextStore.collectiveContexts.count > 1
    }

    var body: some View {
        NavigationStack {
            Group {
                if let group = currentGroup {
                    content(group)
                        .id(group.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                GroupSwitcherToolbarButton(
                                    group: group,
                                    hasMultipleGroups: hasMultipleGroups,
                                    onTap: { isShowingSwitcher = true }
                                )
                            }
                        }
                } else {
                    LaunchNoGroupView(
                        title: emptyTitle,
                        message: emptyMessage,
                        onCreateGroup: onCreateGroup,
                        onJoinGroup: onJoinGroup
                    )
                }
            }
            .task {
                if container.contextStore.phase == .idle {
                    await container.contextStore.load()
                }
                selectFirstGroupIfNeeded()
            }
            .sheet(isPresented: $isShowingSwitcher) {
                ContextSwitcherSheet(
                    container: container,
                    currentContextId: currentGroup?.id
                ) { context in
                    container.contextStore.switchTo(context)
                    Task {
                        await container.contextPreferencesStore.recordVisit(context.id)
                    }
                }
            }
        }
    }

    private func selectFirstGroupIfNeeded() {
        guard let first = container.contextStore.collectiveContexts.first else { return }
        if container.contextStore.currentContext?.isPersonal != false {
            container.contextStore.switchTo(first)
        }
    }
}

/// Switcher de grupo en el leading toolbar item.
/// Muestra ícono + nombre del grupo + chevron. Tap abre `ContextSwitcherSheet`.
/// Si el usuario sólo tiene 1 grupo, el chevron se oculta (no hay a dónde
/// cambiar) pero el botón sigue siendo tappeable para descubrir Crear/Unirme.
private struct GroupSwitcherToolbarButton: View {
    let group: AppContext
    let hasMultipleGroups: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: group.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.callout)
                Text(group.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if hasMultipleGroups {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.tint)
            .frame(maxWidth: 200, alignment: .leading)
        }
        .accessibilityLabel("Cambiar de grupo")
        .accessibilityHint(hasMultipleGroups
            ? "Toca para elegir otro grupo"
            : "Toca para crear o unirte a otro grupo")
    }
}

private struct LaunchNoGroupView: View {
    let title: String
    let message: String
    let onCreateGroup: () -> Void
    let onJoinGroup: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "person.3.fill")
        } description: {
            Text(message)
        } actions: {
            VStack(spacing: 10) {
                Button(action: onCreateGroup) {
                    Label("Crear grupo", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(action: onJoinGroup) {
                    Label("Unirme con código", systemImage: "ticket")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
    }
}

private struct LaunchSettingsView: View {
    let container: DependencyContainer
    let onCreate: () -> Void
    let onJoin: () -> Void

    @State private var isShowingSwitcher = false
    @State private var isShowingInvite = false
    @State private var isShowingGroupSettings = false
    @State private var isShowingMe = false
    @State private var isShowingNotifications = false
    @State private var membersStore: MembersStore

    init(
        container: DependencyContainer,
        onCreate: @escaping () -> Void,
        onJoin: @escaping () -> Void
    ) {
        self.container = container
        self.onCreate = onCreate
        self.onJoin = onJoin
        _membersStore = State(initialValue: MembersStore(rpc: container.rpc))
    }

    private var currentGroup: AppContext? {
        if let current = container.contextStore.currentContext, !current.isPersonal {
            return current
        }
        return container.contextStore.collectiveContexts.first
    }

    var body: some View {
        NavigationStack {
            List {
                groupSection
                if let group = currentGroup {
                    peopleSection(group)
                    rulesSection(group)
                    adminSection(group)
                }
                accountSection
            }
            .navigationTitle("Ajustes")
            .task {
                await container.contextStore.load()
                await container.notificationsStore.load()
                if let group = currentGroup {
                    await membersStore.load(context: group)
                }
            }
            .refreshable {
                await container.contextStore.load()
                await container.notificationsStore.load()
                if let group = currentGroup {
                    await membersStore.load(context: group)
                }
            }
            .sheet(isPresented: $isShowingSwitcher) {
                ContextSwitcherSheet(
                    container: container,
                    currentContextId: currentGroup?.id
                ) { context in
                    container.contextStore.switchTo(context)
                    Task {
                        await container.contextPreferencesStore.recordVisit(context.id)
                        await membersStore.load(context: context)
                    }
                }
            }
            .sheet(isPresented: $isShowingInvite) {
                if let group = currentGroup {
                    InviteMembersView(context: group, store: membersStore, container: container)
                }
            }
            .sheet(isPresented: $isShowingGroupSettings) {
                if let group = currentGroup {
                    ContextSettingsView(context: group, container: container)
                }
            }
            .sheet(isPresented: $isShowingMe) {
                MeView(container: container, goToContexts: { isShowingMe = false })
            }
            .sheet(isPresented: $isShowingNotifications) {
                NotificationCenterView(container: container)
            }
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        Section {
            if let group = currentGroup {
                Button {
                    isShowingSwitcher = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName)
                                .font(.callout.weight(.medium))
                            Text("Grupo actual")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: group.symbolName)
                    }
                }
            }

            Button(action: onCreate) {
                Label("Crear grupo", systemImage: "plus.circle.fill")
            }

            Button(action: onJoin) {
                Label("Unirme con código", systemImage: "ticket")
            }
        } header: {
            Text("Grupo")
        }
    }

    @ViewBuilder
    private func peopleSection(_ group: AppContext) -> some View {
        Section {
            NavigationLink {
                MembersListView(context: group, container: container)
            } label: {
                Label("Miembros", systemImage: "person.3.fill")
            }

            Button {
                isShowingInvite = true
            } label: {
                Label("Invitar amigos", systemImage: "person.badge.plus")
            }
        }
    }

    @ViewBuilder
    private func rulesSection(_ group: AppContext) -> some View {
        Section {
            NavigationLink {
                RulesListView(context: group, container: container)
            } label: {
                Label("Cómo funciona el grupo", systemImage: "ruler.fill")
            }
        } footer: {
            Text("Reglas, multas automáticas y acuerdos del grupo.")
        }
    }

    @ViewBuilder
    private func adminSection(_ group: AppContext) -> some View {
        Section {
            Button {
                isShowingGroupSettings = true
            } label: {
                Label("Administración avanzada", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Administración")
        } footer: {
            Text("Roles, invitaciones, reglas avanzadas y configuración del grupo.")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Button {
                isShowingNotifications = true
            } label: {
                Label(
                    container.notificationsStore.unreadCount > 0
                    ? "Notificaciones (\(container.notificationsStore.unreadCount))"
                    : "Notificaciones",
                    systemImage: container.notificationsStore.unreadCount > 0 ? "bell.badge.fill" : "bell"
                )
            }

            Button {
                isShowingMe = true
            } label: {
                Label("Mi cuenta", systemImage: "person.crop.circle")
            }
        } header: {
            Text("Cuenta")
        }
    }
}

#Preview("Tab Shell (demo)") {
    MainTabShell(container: .demo())
}
