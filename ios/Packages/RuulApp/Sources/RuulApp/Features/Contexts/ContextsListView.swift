import SwiftUI
import RuulCore

/// F.NAV.3 — pantalla dedicada de Contextos. Reemplaza el dropdown del
/// switcher como navegación primaria. Header: "Mis Contextos" · Favoritos ·
/// Todos. Tap → mark_context_visited + switchTo + push `ContextHomeView`.
///
/// Doctrina: la lista la da el backend (`contextStore.availableContexts`,
/// `contextPreferencesStore.favorites`). iOS NO infiere "tipo" — usa
/// `actor_subtype` directo del backend traducido vía table local.
public struct ContextsListView: View {
    let container: DependencyContainer

    @State private var path: [AppContext] = []
    @State private var isShowingCreateContext = false
    @State private var isShowingJoinByCode = false
    @State private var isShowingInvitations = false
    @State private var isShowingContextSettings = false
    @State private var prefilledInviteCode: String?

    public init(container: DependencyContainer) {
        self.container = container
    }

    private var contextStore: ContextStore { container.contextStore }
    private var preferencesStore: ContextPreferencesStore { container.contextPreferencesStore }

    public var body: some View {
        Group {
            switch contextStore.phase {
            case .idle, .loading:
                SessionLoadingView(message: "Cargando tus contextos…")

            case .failed(let message):
                ErrorStateView(title: "No pudimos cargar tus contextos", message: message) {
                    Task { await contextStore.load() }
                }

            case .loaded:
                if contextStore.availableContexts.isEmpty {
                    NoContextsView(
                        onCreate: { isShowingCreateContext = true },
                        onJoin: { isShowingJoinByCode = true },
                        onSignOut: { Task { await container.signOut() } },
                        pendingInvitationsCount: container.invitationsStore.invitations.count,
                        onOpenInvitations: { isShowingInvitations = true }
                    )
                } else {
                    contextsList
                }
            }
        }
        .task {
            await contextStore.load()
            await preferencesStore.load()
            await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
        }
        .refreshable {
            await contextStore.load()
            await preferencesStore.load()
            await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
        }
        .sheet(isPresented: $isShowingCreateContext) {
            CreateContextView(container: container)
        }
        .sheet(isPresented: $isShowingJoinByCode, onDismiss: { prefilledInviteCode = nil }) {
            JoinByCodeView(container: container, prefilledCode: prefilledInviteCode)
        }
        .sheet(isPresented: $isShowingInvitations) {
            PendingInvitationsView(container: container)
        }
        .sheet(isPresented: $isShowingContextSettings) {
            if let current = path.last, !current.isPersonal {
                ContextSettingsView(context: current, container: container)
            }
        }
    }

    // MARK: - Lista principal con secciones

    @ViewBuilder
    private var contextsList: some View {
        List {
            if !preferencesStore.favorites.isEmpty {
                favoritesSection
            }
            allContextsSection
            actionsSection
        }
        .navigationTitle("Mis contextos")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if container.invitationsStore.invitations.isEmpty {
                    EmptyView()
                } else {
                    Button {
                        isShowingInvitations = true
                    } label: {
                        Label("\(container.invitationsStore.invitations.count)", systemImage: "envelope.badge")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Invitaciones pendientes")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingCreateContext = true
                    } label: {
                        Label("Crear contexto", systemImage: "rectangle.split.2x1.fill")
                    }
                    Button {
                        isShowingJoinByCode = true
                    } label: {
                        Label("Unirse con código", systemImage: "key.fill")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .navigationDestination(for: AppContext.self) { context in
            ContextHomeContainer(
                context: context,
                container: container,
                onOpenSettings: { isShowingContextSettings = true }
            )
        }
    }

    // MARK: - Favoritos

    @ViewBuilder
    private var favoritesSection: some View {
        Section {
            ForEach(preferencesStore.favorites) { pref in
                if let ctx = contextStore.availableContexts.first(where: { $0.id == pref.contextActorId }) {
                    contextRow(ctx, isFavorite: true)
                }
            }
        } header: {
            Label("Favoritos", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
        }
    }

    // MARK: - Todos

    @ViewBuilder
    private var allContextsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let nonFavorites = contextStore.availableContexts.filter { !favoriteIds.contains($0.id) }
        Section("Todos") {
            ForEach(nonFavorites) { ctx in
                contextRow(ctx, isFavorite: false)
            }
        }
    }

    // MARK: - Acciones

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                isShowingCreateContext = true
            } label: {
                Label("Crear contexto", systemImage: "rectangle.split.2x1.fill")
            }
            Button {
                isShowingJoinByCode = true
            } label: {
                Label("Unirse con código", systemImage: "key.fill")
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func contextRow(_ context: AppContext, isFavorite: Bool) -> some View {
        Button {
            openContext(context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: context.symbolName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        if let subtitle = subtypeLabel(context) {
                            Text(subtitle)
                        }
                        if !context.isPersonal {
                            Text("·")
                            Text("\(context.memberCount) miembros")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                if !context.isPersonal {
                    Button {
                        Task {
                            try? await preferencesStore.setFavorite(context.id, isFavorite: !isFavorite)
                        }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isFavorite ? "Quitar de favoritos" : "Agregar a favoritos")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Abre el contexto: registra visita (best-effort) + switch al store +
    /// push a ContextHomeView.
    private func openContext(_ context: AppContext) {
        contextStore.switchTo(context)
        Task { await preferencesStore.recordVisit(context.id) }
        path.append(context)
    }

    private func subtypeLabel(_ context: AppContext) -> String? {
        if context.isPersonal { return "Tu contexto personal" }
        switch context.subtype {
        case "family":       return "Familia"
        case "friend_group": return "Grupo"
        case "community":    return "Comunidad"
        case "project":      return "Proyecto"
        case "trip":         return "Viaje"
        case "company":      return "Negocio"
        case "trust":        return "Trust"
        default:             return context.subtype
        }
    }
}

// MARK: - Wrapper que envuelve ContextHomeView con su toolbar de settings

/// F.NAV.3 — Wrapper que apila ContextHomeView con el toolbar de settings y
/// breadcrumb. Replica las responsabilidades de ContextShell.contextRoot sin
/// la NavigationStack (la dueña es ContextsListView).
private struct ContextHomeContainer: View {
    let context: AppContext
    let container: DependencyContainer
    let onOpenSettings: () -> Void

    var body: some View {
        ContextHomeView(context: context, container: container)
            .toolbar {
                if !context.isPersonal {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onOpenSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Configuración del contexto")
                    }
                }
            }
            // Rebuild en cambio de contexto.
            .id(context.id)
    }
}

#Preview("ContextsList (demo)") {
    NavigationStack {
        ContextsListView(container: .demo())
    }
}
