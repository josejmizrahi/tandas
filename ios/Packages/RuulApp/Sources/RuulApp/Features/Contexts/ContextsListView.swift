import SwiftUI
import RuulCore

/// F.CONTEXT.2 — pantalla de Contextos escalable. Reemplaza la List monolítica
/// por un dashboard que escala a cientos de contextos:
///
///   Mi espacio       (hero card único, atajo al contexto personal)
///   ⭐ Favoritos     (cards horizontales, scrollable)
///   ⏱ Recientes     (cards horizontales, scrollable)
///   Todos            (lista inline, sólo raíces no-personales)
///   Crear / Unirse   (card de acciones)
///
/// El botón "+" del toolbar desaparece — la tab central "Crear" + esta card
/// inline cubren la intención. F.2X intent-first.
public struct ContextsListView: View {
    let container: DependencyContainer

    /// Path del NavigationStack. Owneado por `MainTabShell` para que
    /// `jumpToContext` desde Home pueda empujar al ContextHome target.
    @Binding var path: [AppContext]
    @State private var isShowingCreateContext = false
    @State private var isShowingJoinByCode = false
    @State private var isShowingInvitations = false
    @State private var isShowingContextSettings = false
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
        .sheet(isPresented: $isShowingContextSettings) {
            if let current = path.last, !current.isPersonal {
                ContextSettingsView(context: current, container: container)
            }
        }
    }

    // MARK: - Dashboard

    @ViewBuilder
    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 24) {
                miEspacioCard
                favoritesSection
                recentsSection
                allContextsSection
                actionsCard
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 32)
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
            // F.CONTEXT.2 — "+" del toolbar eliminado. La tab central "Crear"
            // + la card "Crear contexto / Unirse" cubren la intención.
        }
        .navigationDestination(for: AppContext.self) { context in
            ContextHomeContainer(
                context: context,
                container: container,
                onOpenSettings: { isShowingContextSettings = true },
                onSwitchContext: { newCtx in
                    container.contextStore.switchTo(newCtx)
                    Task { await container.contextPreferencesStore.recordVisit(newCtx.id) }
                    path.removeAll()
                    path.append(newCtx)
                }
            )
        }
    }

    // MARK: - Mi espacio (hero card único)

    @ViewBuilder
    private var miEspacioCard: some View {
        if let personal = contextStore.availableContexts.first(where: { $0.isPersonal }) {
            Button {
                openContext(personal)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: personal.symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.badgeFill, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mi espacio")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Tu actividad, recursos y compromisos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Favoritos (cards horizontales)

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = resolveContexts(ids: preferencesStore.favorites.map(\.contextActorId))
            .filter { $0.isRoot && !$0.isPersonal }
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Favoritos", systemImage: "star.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.yellow)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(favorites) { ctx in
                            contextCard(ctx, isFavorite: true)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Recientes (cards horizontales)

    @ViewBuilder
    private var recentsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let recents = resolveContexts(ids: preferencesStore.recents.map(\.contextActorId))
            .filter { $0.isRoot && !$0.isPersonal && !favoriteIds.contains($0.id) }
            .prefix(8)
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Recientes", systemImage: "clock")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(recents)) { ctx in
                            contextCard(ctx, isFavorite: false)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Todos (lista inline)

    @ViewBuilder
    private var allContextsSection: some View {
        let favoriteIds = Set(preferencesStore.favorites.map(\.contextActorId))
        let allRoots = contextStore.availableContexts.filter { $0.isRoot && !$0.isPersonal }
        if !allRoots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Todos")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(allRoots.enumerated()), id: \.element.id) { idx, ctx in
                        Button {
                            openContext(ctx)
                        } label: {
                            contextRowContent(ctx, isFavorite: favoriteIds.contains(ctx.id))
                        }
                        .buttonStyle(.plain)
                        if idx < allRoots.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    // MARK: - Acciones (card al final)

    @ViewBuilder
    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                isShowingCreateContext = true
            } label: {
                actionRow(symbol: "rectangle.split.2x1.fill", title: "Crear contexto")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, Theme.Spacing.dividerLeading)

            Button {
                isShowingJoinByCode = true
            } label: {
                actionRow(symbol: "key.fill", title: "Unirse con código")
            }
            .buttonStyle(.plain)
        }
        .background(Theme.Surface.card, in: Theme.cardShape())
    }

    @ViewBuilder
    private func actionRow(symbol: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 32)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Cards / rows

    @ViewBuilder
    private func contextCard(_ ctx: AppContext, isFavorite: Bool) -> some View {
        Button {
            openContext(ctx)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: ctx.symbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.badgeFill, in: Circle())
                    Spacer()
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Spacer(minLength: 0)
                Text(ctx.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(cardCaption(ctx))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, height: 150, alignment: .topLeading)
            .padding(16)
            .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
            .overlay(
                Theme.cardShape(Theme.Radius.cardHero)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
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

    @ViewBuilder
    private func contextRowContent(_ ctx: AppContext, isFavorite: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ctx.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.badgeFillSubtle, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let subtitle = subtypeLabel(ctx) {
                        Text(subtitle)
                    }
                    Text("·")
                    Text("\(ctx.memberCount) miembros")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button {
                Task {
                    try? await preferencesStore.setFavorite(ctx.id, isFavorite: !isFavorite)
                }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Quitar de favoritos" : "Agregar a favoritos")
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func openContext(_ context: AppContext) {
        contextStore.switchTo(context)
        Task { await preferencesStore.recordVisit(context.id) }
        path.append(context)
    }

    /// Resuelve UUIDs a `AppContext`s en orden de entrada, preservando duplicados eliminados.
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

// MARK: - Wrapper que envuelve ContextHomeView con su toolbar de settings + switcher sheet

/// F.NAV.3+F.NAV.4 — Wrapper que apila ContextHomeView con:
///   - Título tap → sheet `ContextSwitcherSheet` (F.NAV.4).
///   - Gear de settings en toolbar (sólo no-personales).
private struct ContextHomeContainer: View {
    let context: AppContext
    let container: DependencyContainer
    let onOpenSettings: () -> Void
    let onSwitchContext: (AppContext) -> Void

    @State private var isShowingSwitcher = false

    var body: some View {
        ContextHomeView(context: context, container: container)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        isShowingSwitcher = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(context.isPersonal ? "Mi espacio" : context.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
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
