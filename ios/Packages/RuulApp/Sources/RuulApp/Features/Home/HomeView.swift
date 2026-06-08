import SwiftUI
import RuulCore

/// F.NAV.10 — Home rebuild segundo pase con prioridad founder.
///
/// Cambios doctrinales vs F.NAV.9:
/// - Sin nav title "Ruul" (el greeting es el único header).
/// - Atención SIEMPRE visible (empty state ✓ dentro de la card) para que
///   la estructura no cambie cuando llega un pendiente nuevo.
/// - Orden: Greeting → Atención → Continuar → Actividad reciente → Herramientas.
/// - Crear se elimina del grid: vive sólo en el tab central de la TabView.
/// - Herramientas = sólo Buscar / Preguntar a Ruul / Escanear, todas con
///   "Próximamente". Cero mezcla de enabled+disabled en el mismo grid.
/// - Actividad inline (3 items recientes) + "Ver todo →".
public struct HomeView: View {
    let container: DependencyContainer
    let jumpToContext: (AppContext) -> Void
    let onTriggerCreate: () -> Void

    // R.5Y.A2 — Único state que captura la intención del dispatcher.
    @State private var presentedAttention: AttentionDestination?
    @State private var isShowingAllAttention = false
    /// F.NAV.10 — preview inline de actividad reciente.
    @State private var activityStore: ActivityFeedStore

    public init(container: DependencyContainer, jumpToContext: @escaping (AppContext) -> Void, onTriggerCreate: @escaping () -> Void) {
        self.container = container
        self.jumpToContext = jumpToContext
        self.onTriggerCreate = onTriggerCreate
        _activityStore = State(initialValue: ActivityFeedStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    heroSection
                    attentionSection
                    continueSection
                    activitySection
                    toolsSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await activityStore.load()
            }
            .refreshable {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await activityStore.reload()
            }
            .sheet(item: $presentedAttention) { destination in
                AttentionDestinationSheet(destination: destination, container: container)
            }
            .sheet(isPresented: $isShowingAllAttention) {
                NavigationStack {
                    AllAttentionView(container: container) { item in
                        isShowingAllAttention = false
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    }
                }
            }
        }
    }

    // MARK: - 1. Hero greeting (sin "Ruul")

    @ViewBuilder
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting + ",")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(container.currentActorStore.actor?.displayName ?? "Hola")
                .font(.largeTitle.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Buenos días"
        case 12..<19: return "Buenas tardes"
        default:      return "Buenas noches"
        }
    }

    // MARK: - 2. Atención (SIEMPRE visible)

    @ViewBuilder
    private var attentionSection: some View {
        let items = container.attentionInboxStore.items
        if items.isEmpty {
            // Empty state dentro de la misma card → estructura estable.
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atención")
                        .font(.subheadline.weight(.semibold))
                    Text("Todo está al día")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.Surface.card, in: Theme.cardShape())
        } else {
            Button {
                if items.count == 1 {
                    presentedAttention = AttentionDispatcher.destination(for: items[0])
                } else {
                    isShowingAllAttention = true
                }
            } label: {
                VStack(spacing: 0) {
                    HStack {
                        Label("Requiere tu atención", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(items.count == 1 ? "Ver \(Image(systemName: "chevron.right"))" : "Ver \(items.count) \(Image(systemName: "chevron.right"))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider().padding(.leading, 16)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items.prefix(3)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: AttentionPresentation.symbol(for: item.kind))
                                    .font(.callout)
                                    .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.contextDisplayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        if items.count > 3 {
                            Text("+ \(items.count - 3) más")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 32)
                        }
                    }
                    .padding(16)
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 3. Continuar (carrusel horizontal)

    @ViewBuilder
    private var continueSection: some View {
        let recents = container.contextPreferencesStore.recents
        let resolved = recents.compactMap { pref in
            container.contextStore.availableContexts.first { $0.id == pref.contextActorId }
        }
        if !resolved.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Continuar")
                    .font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(resolved) { ctx in
                            continueCard(ctx)
                        }
                    }
                    .padding(.bottom, 4) // espacio para shadow
                }
            }
        }
    }

    @ViewBuilder
    private func continueCard(_ ctx: AppContext) -> some View {
        Button {
            jumpToContext(ctx)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: ctx.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.badgeFill, in: Circle())
                Spacer(minLength: 0)
                Text(ctx.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if ctx.isPersonal {
                    Text("Personal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(ctx.memberCount) miembros")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160, alignment: .topLeading)
            .padding(16)
            .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
            .overlay(
                Theme.cardShape(Theme.Radius.cardHero)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4. Actividad reciente (inline preview)

    @ViewBuilder
    private var activitySection: some View {
        let items = activityStore.items.prefix(3)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actividad reciente")
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink {
                    MyActivityFeedView(container: container)
                } label: {
                    Text("Ver todo \(Image(systemName: "chevron.right"))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                if activityStore.phase.isLoading && activityStore.items.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Cargando…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding()
                } else if items.isEmpty {
                    Text("Sin actividad reciente.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        activityRow(item)
                        if idx < items.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func activityRow(_ item: FeedItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(sourceColor(item.source).badgeFill)
                    .frame(width: 32, height: 32)
                Image(systemName: item.asActivityEvent.symbolName)
                    .font(.callout)
                    .foregroundStyle(sourceColor(item.source))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.asActivityEvent.friendlyTitle(currentActorId: container.currentActorStore.actorId))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let ctxName = contextName(for: item.contextActorId) {
                        Text(ctxName)
                    }
                    if let occurred = item.occurredAt {
                        Text("·")
                        Text(occurred.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sourceColor(_ source: FeedSource) -> Color {
        Theme.Source.tint(source)
    }

    private func contextName(for contextActorId: UUID?) -> String? {
        guard let id = contextActorId else { return nil }
        return container.contextStore.availableContexts.first { $0.id == id }?.displayName
    }

    // MARK: - 5. Herramientas (sólo Próximamente)

    @ViewBuilder
    private var toolsSection: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Herramientas")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Próximamente")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                toolTile(label: "Buscar", icon: "magnifyingglass")
                toolTile(label: "Preguntar a Ruul", icon: "sparkles")
                toolTile(label: "Escanear", icon: "qrcode.viewfinder")
            }
        }
    }

    @ViewBuilder
    private func toolTile(label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .padding(14)
        .background(Theme.Surface.card, in: Theme.cardShape())
        .opacity(0.7)
    }

    // MARK: - Routing de atención (R.5Y.A2: delegado al AttentionDispatcher)
    //
    // El handleTap / attentionDestination / attentionSymbol / attentionTint
    // que vivían aquí fueron reemplazados por:
    //   - AttentionDispatcher.destination(for: item) → AttentionDestination
    //   - AttentionDestinationSheet(destination:, container:)
    //   - AttentionPresentation.symbol(for:) / .tint(for:)
    // Esto unifica el routing entre HomeView, ContextDetailViewV2 y ContextHomeView.
}

// MARK: - Sheet "Todos los pendientes"

private struct AllAttentionView: View {
    let container: DependencyContainer
    let onTap: (AttentionItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(container.attentionInboxStore.items) { item in
                Button {
                    onTap(item)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: AttentionPresentation.symbol(for: item.kind))
                            .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.medium))
                            Text("\(item.contextDisplayName) · \(item.reason)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Pendientes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }

}

#Preview("Home (demo)") {
    HomeView(container: .demo(), jumpToContext: { _ in }, onTriggerCreate: {})
}
