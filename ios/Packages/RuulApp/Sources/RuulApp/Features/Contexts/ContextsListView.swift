import SwiftUI
import RuulCore

/// F.CONTEXT.2 + R.5V.X refactor 2026-06-08 — pantalla de Contextos Apple-native.
///
/// Doctrina canónica firmada V.3/V.4/V.5: **la Section ES la card**. Cero VStack
/// envueltos en `Theme.cardShape()`. List + Section grouped + Label native +
/// NavigationLink (chevron auto).
///
/// Estructura visual:
/// ```
/// List(.insetGrouped) {
///   Section { "Mi espacio" row }                  // NavigationLink + Label icon
///   Section "Favoritos" { carousel horizontal }   // .listRowInsets(.zero)
///   Section "Recientes" { carousel horizontal }   // .listRowInsets(.zero)
///   Section "Todos los contextos" { Label rows }  // chevron auto + favorite swipe
///   Section { "Crear contexto" / "Unirse" Label rows }
/// }
/// ```
///
/// Cero break: NavigationStack path + sheets + navigationDestination + toolbar
/// invitations badge se preservan idénticos.
public struct ContextsListView: View {
    let container: DependencyContainer

    @Binding var path: [AppContext]
    @State private var isShowingCreateContext = false
    @State private var isShowingJoinByCode = false
    @State private var isShowingInvitations = false
    @State private var settingsContext: AppContext?
    @State private var prefilledInviteCode: String?

    public init(container: DependencyContainer, path: Binding<[AppContext]>) {
        self.container = container
        self._path = path
    }

    private var contextStore: ContextStore { container.contextStore }
    private var preferencesStore: ContextPreferencesStore { container.contextPreferencesStore }

    public var body: some View {
        NavigationStack(path: $path) {
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
                        dashboard
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
        .sheet(item: $settingsContext) { ctx in
            ContextSettingsView(context: ctx, container: container)
        }
    }

    // MARK: - Dashboard (Apple-native List + Section)

    @ViewBuilder
    private var dashboard: some View {
        List {
            miEspacioSection
            favoritesSection
            recentsSection
            allContextsSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mis contextos")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !container.invitationsStore.invitations.isEmpty {
                    Button {
                        isShowingInvitations = true
                    } label: {
                        Label(
                            "\(container.invitationsStore.invitations.count)",
                            systemImage: "envelope.badge"
                        )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.Tint.warning)
                    }
                    .accessibilityLabel("Invitaciones pendientes")
                }
            }
        }
        .navigationDestination(for: AppContext.self) { context in
            ContextHomeContainer(
                context: context,
                container: container,
                onOpenSettings: {
                    if !context.isPersonal { settingsContext = context }
                },
                onSwitchContext: { newCtx in
                    container.contextStore.switchTo(newCtx)
                    Task { await container.contextPreferencesStore.recordVisit(newCtx.id) }
                    path.removeAll()
                    path.append(newCtx)
                }
            )
            .environment(\.navigateToContext, NavigateToContextAction { target in
                container.contextStore.switchTo(target)
                Task { await container.contextPreferencesStore.recordVisit(target.id) }
                path.removeAll()
                path.append(target)
            })
        }
    }

    // MARK: - Mi espacio (Section row con NavigationLink — chevron auto)

    @ViewBuilder
    private var miEspacioSection: some View {
        if let personal = contextStore.availableContexts.first(where: { $0.isPersonal }) {
            Section {
                Button {
                    openContext(personal)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mi espacio")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text("Tu actividad, recursos y compromisos")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: personal.symbolName)
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
            }
        }
    }

    // MARK: - Favoritos (horizontal carousel embebido en row)

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = resolveContexts(ids: preferencesStore.favorites.map(\.contextActorId))
            .filter { $0.isRoot && !$0.isPersonal }
        if !favorites.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(favorites) { ctx in
                            contextCard(ctx, isFavorite: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Label("Favoritos", systemImage: "star.fill")
                    .foregroundStyle(Theme.Tint.warning)
            }
        }
    }

    // MARK: - Recientes (carousel)

    @ViewBuilder
    private var recentsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let recents = resolveContexts(ids: preferencesStore.recents.map(\.contextActorId))
            .filter { $0.isRoot && !$0.isPersonal && !favoriteIds.contains($0.id) }
            .prefix(8)
        if !recents.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(recents)) { ctx in
                            contextCard(ctx, isFavorite: false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Label("Recientes", systemImage: "clock")
            }
        }
    }

    // MARK: - Todos los contextos (Label rows nativos con favorite swipe action)

    @ViewBuilder
    private var allContextsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let allRoots = contextStore.availableContexts.filter { $0.isRoot && !$0.isPersonal }
        if !allRoots.isEmpty {
            Section {
                ForEach(allRoots) { ctx in
                    Button {
                        openContext(ctx)
                    } label: {
                        contextRowLabel(ctx, isFavorite: favoriteIds.contains(ctx.id))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        let fav = favoriteIds.contains(ctx.id)
                        Button {
                            Task {
                                try? await preferencesStore.setFavorite(ctx.id, isFavorite: !fav)
                            }
                        } label: {
                            Label(
                                fav ? "Quitar" : "Favorito",
                                systemImage: fav ? "star.slash.fill" : "star.fill"
                            )
                        }
                        .tint(Theme.Tint.warning)
                    }
                }
            } header: {
                Text("Todos los contextos (\(allRoots.count))")
            }
        }
    }

    @ViewBuilder
    private func contextRowLabel(_ ctx: AppContext, isFavorite: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ctx.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                Text(rowCaption(ctx))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: ctx.symbolName)
                .foregroundStyle(Theme.Tint.primary)
        }
    }

    private func rowCaption(_ ctx: AppContext) -> String {
        let kind = subtypeLabel(ctx) ?? ""
        if ctx.memberCount > 0 {
            return kind.isEmpty
                ? "\(ctx.memberCount) miembros"
                : "\(kind) · \(ctx.memberCount) miembros"
        }
        return kind.isEmpty ? "Sin miembros" : kind
    }

    // MARK: - Acciones (Section con Label rows nativos)

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
        } header: {
            Text("Espacio nuevo")
        }
    }

    // MARK: - Card visual (carousel — Apple Home / V.3 Continuar pattern)

    @ViewBuilder
    private func contextCard(_ ctx: AppContext, isFavorite: Bool) -> some View {
        Button {
            openContext(ctx)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: ctx.symbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 40, height: 40)
                        .background(Theme.Tint.primary.opacity(0.12), in: Circle())
                    Spacer()
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                Spacer(minLength: 0)
                Text(ctx.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(cardCaption(ctx))
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, height: 140, alignment: .topLeading)
            .padding(14)
            .background(Theme.Background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func cardCaption(_ ctx: AppContext) -> String {
        let kind = subtypeLabel(ctx) ?? ""
        if ctx.memberCount > 0 {
            return kind.isEmpty
                ? "\(ctx.memberCount) miembros"
                : "\(kind) · \(ctx.memberCount)"
        }
        return kind
    }

    // MARK: - Helpers

    private func openContext(_ context: AppContext) {
        contextStore.switchTo(context)
        Task { await preferencesStore.recordVisit(context.id) }
        path.append(context)
    }

    private func resolveContexts(ids: [UUID]) -> [AppContext] {
        var seen = Set<UUID>()
        var out: [AppContext] = []
        for id in ids {
            guard !seen.contains(id),
                  let ctx = contextStore.availableContexts.first(where: { $0.id == id }) else { continue }
            seen.insert(id)
            out.append(ctx)
        }
        return out
    }

    private func subtypeLabel(_ context: AppContext) -> String? {
        if context.isPersonal { return nil }
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

// MARK: - Wrapper que envuelve ContextDetailViewV2 con toolbar (gear + switcher)

/// F.NAV.3+F.NAV.4 — Wrapper que apila ContextDetailViewV2 con:
///   - Título tap → sheet `ContextSwitcherSheet` (F.NAV.4).
///   - Gear de settings en toolbar (sólo no-personales).
private struct ContextHomeContainer: View {
    let context: AppContext
    let container: DependencyContainer
    let onOpenSettings: () -> Void
    let onSwitchContext: (AppContext) -> Void

    @State private var isShowingSwitcher = false

    var body: some View {
        ContextDetailViewV2(contextId: context.id, context: context, container: container)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        isShowingSwitcher = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(context.isPersonal ? "Mi espacio" : context.displayName)
                                .font(.headline)
                                .foregroundStyle(Theme.Text.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cambiar contexto. Actual: \(context.displayName)")
                }
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
            .sheet(isPresented: $isShowingSwitcher) {
                ContextSwitcherSheet(
                    container: container,
                    currentContextId: context.id,
                    onSwitch: onSwitchContext
                )
            }
            .id(context.id)
    }
}

#Preview("ContextsList (demo)") {
    @Previewable @State var path: [AppContext] = []
    NavigationStack {
        ContextsListView(container: .demo(), path: $path)
    }
}
