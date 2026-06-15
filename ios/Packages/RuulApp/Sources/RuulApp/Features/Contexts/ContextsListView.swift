import SwiftUI
import RuulCore

/// R.11.E.3 — Contextos lista densa (founder firmado 2026-06-16).
///
/// Diferenciación fuerte vs Home: aquí navegas el catálogo de espacios
/// con métricas vivas inline; Home queda operacional (Atención + "Hoy en
/// tus espacios"). Cambios vs R.5V.3A:
/// - Quitar "Recientes" carousel — la lista default-sort por last_visited
///   absorbe la función.
/// - "Todos los espacios" rows ahora densos: pendientes badge + balance
///   preview + próximo evento (priorizado igual que Home).
/// - Powered by `home_overview()` RPC (R.11.E.0).
///
/// Estructura visual:
/// ```
/// List(.insetGrouped) {
///   Section { RuulHeroCard "Mi espacio" }
///   Section "Favoritos" { carousel horizontal }
///   Section "Todos los espacios" { rows densos con métricas }  // sort by last_visited
///   Section "Acciones" { Crear espacio / Unirse con código }
/// }
/// .searchable(text: $searchText, prompt: "Buscar espacios")
/// ```
public struct ContextsListView: View {
    let container: DependencyContainer

    @Binding var path: [AppContext]
    @State private var isShowingCreateContext = false
    @State private var isShowingJoinByCode = false
    @State private var isShowingInvitations = false
    @State private var prefilledInviteCode: String?
    @State private var searchText = ""
    /// R.11.E.3 — Map context_actor_id → ContextOverview para enriquecer
    /// cada row con métricas vivas (pending/balance/next_event).
    @State private var overviewMap: [UUID: ContextOverview] = [:]
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
                    RuulSkeletonList(rows: 7)

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
                await loadOverviews()
            }
            .refreshable {
                await contextStore.load()
                await preferencesStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await loadOverviews()
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

    private func loadOverviews() async {
        do {
            let list = try await container.rpc.homeOverview()
            overviewMap = Dictionary(uniqueKeysWithValues: list.map { ($0.contextActorId, $0) })
        } catch {
            overviewMap = [:]
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
                allContextsSection
                actionsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mis espacios")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Buscar espacios"
        )
        .searchToolbarBehavior(.minimize)
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

    // MARK: - Todos los espacios (R.11.E.3 — rows densos con métricas vivas)

    @ViewBuilder
    private var allContextsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let allRoots = contextStore.availableContexts.filter { $0.isRoot && !$0.isPersonal }
        // R.11.E.3 — Sort by last_visited (descending) from overviewMap;
        // fallback al final si no hay overview todavía. Absorbe la función
        // de "Recientes" carousel removido.
        let sorted = allRoots.sorted { (a, b) in
            let aVisited = overviewMap[a.id]?.lastVisitedAt ?? .distantPast
            let bVisited = overviewMap[b.id]?.lastVisitedAt ?? .distantPast
            if aVisited != bVisited { return aVisited > bVisited }
            return a.displayName < b.displayName
        }
        if !sorted.isEmpty {
            Section {
                ForEach(sorted) { ctx in
                    Button {
                        openContext(ctx)
                    } label: {
                        contextRowLabel(ctx, isFavorite: favoriteIds.contains(ctx.id), overview: overviewMap[ctx.id])
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
                Text("Todos los espacios (\(sorted.count))")
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
                        contextRowLabel(ctx, isFavorite: favoriteIds.contains(ctx.id), overview: overviewMap[ctx.id])
                    }
                }
            } header: {
                Text("Resultados (\(matches.count))")
            }
        }
    }

    @ViewBuilder
    private func contextRowLabel(_ ctx: AppContext, isFavorite: Bool, overview: ContextOverview?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ctx.isPersonal ? "Mi espacio" : ctx.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isFavorite ? Theme.Tint.warning : .clear)
                        .contentTransition(.symbolEffect(.replace))
                    if let pendingCount = overview?.pendingCount, pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.Tint.warning.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                Text(rowCaption(ctx, overview: overview))
                    .font(.caption)
                    .foregroundStyle(rowCaptionTint(overview))
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: ctx.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.primary)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    /// R.11.E.3 — Caption rico priorizado por actionability:
    /// pendientes > balance ≠ 0 > próximo evento > miembros (legacy fallback).
    private func rowCaption(_ ctx: AppContext, overview: ContextOverview?) -> String {
        if let overview {
            if overview.pendingCount > 0 {
                return overview.pendingCount == 1 ? "1 pendiente" : "\(overview.pendingCount) pendientes"
            }
            if let balance = overview.myBalance, let currency = overview.balanceCurrency, balance < 0 {
                return "Debes " + balance.compactCurrencyLabel(currency)
            }
            if let when = overview.nextEventAt {
                if let title = overview.nextEventTitle {
                    return "\(rowEventWhen(when)) · \(title)"
                }
                return rowEventWhen(when)
            }
            if let balance = overview.myBalance, let currency = overview.balanceCurrency, balance > 0 {
                return "Te deben " + balance.compactCurrencyLabel(currency)
            }
        }
        // Fallback legacy: subtype + member count.
        let kind = subtypeLabel(ctx) ?? ""
        let memberCount = overview?.memberCount ?? ctx.memberCount
        if memberCount > 0 {
            return kind.isEmpty
                ? "\(memberCount) miembros"
                : "\(kind) · \(memberCount) miembros"
        }
        return kind.isEmpty ? "Sin miembros" : kind
    }

    private func rowCaptionTint(_ overview: ContextOverview?) -> Color {
        guard let overview else { return Theme.Text.secondary }
        if overview.pendingCount > 0 { return Theme.Tint.warning }
        if let balance = overview.myBalance, balance < 0 { return Theme.Tint.critical }
        if overview.nextEventAt != nil { return Theme.Tint.primary }
        if let balance = overview.myBalance, balance > 0 { return Theme.Tint.success }
        return Theme.Text.secondary
    }

    private func rowEventWhen(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Hoy " + date.formatted(.dateTime.hour().minute())
        }
        if cal.isDateInTomorrow(date) {
            return "Mañana " + date.formatted(.dateTime.hour().minute())
        }
        let days = cal.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.wide)).capitalized
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
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
