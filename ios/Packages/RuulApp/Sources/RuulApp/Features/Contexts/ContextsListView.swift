import SwiftUI
import RuulCore

/// R.5V.3A (2026-06-08) — pantalla de Contextos Apple-native refinada.
///
/// Founder UX refinement: jerarquía visual clara con Mi espacio como Hero
/// principal, búsqueda integrada para escalabilidad, terminología visible
/// ("espacios" en lugar de "contextos"), y Recientes condicional que no
/// duplica información de "Todos los espacios".
///
/// Estructura visual:
/// ```
/// List(.insetGrouped) {
///   Section { RuulHeroCard "Mi espacio" }            // listRowInsets.zero — hero
///   Section "Favoritos" { carousel horizontal }
///   Section "Recientes" { carousel horizontal }      // solo si < all_contexts
///   Section "Todos los espacios" { Label rows }
///   Section "Acciones" { Crear espacio / Unirse }
/// }
/// .searchable(text: $searchText, prompt: "Buscar espacios")
/// ```
///
/// El backend sigue siendo "contexto" — solo el copy visible cambia.
public struct ContextsListView: View {
    let container: DependencyContainer

    @Binding var path: [AppContext]
    @State private var isShowingCreateContext = false
    @State private var isShowingJoinByCode = false
    @State private var isShowingInvitations = false
    @State private var prefilledInviteCode: String?
    @State private var searchText = ""
    /// R.5V.Zoom — Namespace para `matchedTransitionSource` + `.navigationTransition(.zoom)`.
    @Namespace private var zoomNamespace

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
                    SessionLoadingView(message: "Cargando tus espacios…")

                case .failed(let message):
                    RuulErrorState(title: "No pudimos cargar tus espacios", message: message) {
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
    }

    // MARK: - Dashboard (Apple-native List + Section + searchable)

    @ViewBuilder
    private var dashboard: some View {
        List {
            if isSearching {
                searchResultsSection
            } else {
                miEspacioHeroSection
                favoritesSection
                recentsSection
                allContextsSection
                actionsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mis Contextos")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Buscar espacios"
        )
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
            // R.5V.Zoom — zoom transition desde el card source matcheado por ctx.id.
            .navigationTransition(.zoom(sourceID: context.id, in: zoomNamespace))
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Mi espacio Hero (RuulHeroCard inside listRowInsets.zero)

    @ViewBuilder
    private var miEspacioHeroSection: some View {
        if let personal = contextStore.availableContexts.first(where: { $0.isPersonal }) {
            Section {
                Button {
                    openContext(personal)
                } label: {
                    RuulHeroCard(
                        title: "Mi espacio",
                        subtitle: "Tu actividad, recursos y compromisos",
                        systemImage: personal.symbolName,
                        tint: Theme.Tint.primary
                    ) {
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Entrar")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.Tint.primary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            ForEach(favorites) { ctx in
                                contextCard(ctx, isFavorite: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .scrollTargetLayout()
                    }
                }
                .scrollTargetBehavior(.viewAligned)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Label("Favoritos", systemImage: "star.fill")
                    .foregroundStyle(Theme.Tint.warning)
            }
        }
    }

    // MARK: - Recientes (solo si recents > 0 y recents < all_contexts)

    @ViewBuilder
    private var recentsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let allRootsCount = contextStore.availableContexts.filter { $0.isRoot && !$0.isPersonal }.count
        let recents = resolveContexts(ids: preferencesStore.recents.map(\.contextActorId))
            .filter { $0.isRoot && !$0.isPersonal && !favoriteIds.contains($0.id) }
            .prefix(8)
        if !recents.isEmpty && recents.count < allRootsCount {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            ForEach(Array(recents)) { ctx in
                                contextCard(ctx, isFavorite: false)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .scrollTargetLayout()
                    }
                }
                .scrollTargetBehavior(.viewAligned)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Label("Recientes", systemImage: "clock")
            }
        }
    }

    // MARK: - Todos los espacios (Label rows nativos con favorite swipe action)

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
                Text("Todos los espacios (\(allRoots.count))")
            }
        }
    }

    // MARK: - Search results (cuando hay texto en searchable)

    @ViewBuilder
    private var searchResultsSection: some View {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = contextStore.availableContexts.filter { ctx in
            guard ctx.isRoot else { return false }
            if ctx.displayName.lowercased().contains(needle) { return true }
            if let sub = subtypeLabel(ctx)?.lowercased(), sub.contains(needle) { return true }
            return false
        }
        if matches.isEmpty {
            Section {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
            Section {
                ForEach(matches) { ctx in
                    Button {
                        openContext(ctx)
                    } label: {
                        contextRowLabel(ctx, isFavorite: favoriteIds.contains(ctx.id))
                    }
                }
            } header: {
                Text("Resultados (\(matches.count))")
            }
        }
    }

    @ViewBuilder
    private func contextRowLabel(_ ctx: AppContext, isFavorite: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ctx.isPersonal ? "Mi espacio" : ctx.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    // R.5V.Symbols.C4 — Image siempre montado: vista mantiene
                    // identidad y SwiftUI hace morph nativo en lugar de fade
                    // al cambiar isFavorite. Mismo patrón en card abajo.
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isFavorite ? Theme.Tint.warning : .clear)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(rowCaption(ctx))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: ctx.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.primary)
                .contentTransition(.symbolEffect(.replace))
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
                Label("Crear espacio", systemImage: "rectangle.split.2x1.fill")
            }
            Button {
                isShowingJoinByCode = true
            } label: {
                Label("Unirse con código", systemImage: "key.fill")
            }
        } header: {
            Text("Acciones")
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
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 40, height: 40)
                        .background(Theme.Tint.primary.opacity(0.12), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isFavorite ? Theme.Tint.warning : .clear)
                        .contentTransition(.symbolEffect(.replace))
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
            // R.5V.Glass.C2 founder feedback — mismo Liquid Glass interactivo
            // que los children cards en ContextDetailViewV2.
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: ctx.id, in: zoomNamespace)
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
    let onSwitchContext: (AppContext) -> Void

    @State private var isShowingSwitcher = false

    var body: some View {
        // Configuración vive dentro del Menu ellipsis de ContextDetailViewV2
        // (sección "Configuración"). NO duplicar con un gear adicional aquí.
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
                    .accessibilityLabel("Cambiar espacio. Actual: \(context.displayName)")
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
