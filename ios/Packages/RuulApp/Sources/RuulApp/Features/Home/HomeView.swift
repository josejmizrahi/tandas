import SwiftUI
import RuulCore

/// R.5V.3 — Home Apple-native (List + Section). Refactor del scroll + cards custom
/// del F.NAV.10 anterior. Doctrina canónica firmada por founder 2026-06-07:
/// **la Section ES la card** — sin VStack envueltos en `Theme.cardShape()`.
///
/// Estructura:
/// ```
/// List(.insetGrouped) {
///   Section { hero greeting }              // .clear bg + no separator
///   Section("Atención") { rows }           // empty row OR up to 3 + "ver más"
///   Section("Continuar") { carousel row }  // horizontal scroll inside row
///   Section("Actividad reciente") { rows + "ver toda" link }
///   Section("Herramientas") { disabled labels } footer "Próximamente"
/// }
/// ```
///
/// Las acciones de atención delegan a `AttentionDispatcher` (R.5Y.A2) sin cambios.
/// Las Reglas (R.6.0 futuro) emitirán `emit_attention` → ya cae en la sección de
/// Atención sin cambios estructurales aquí.
public struct HomeView: View {
    let container: DependencyContainer
    let jumpToContext: (AppContext) -> Void
    let onTriggerCreate: () -> Void

    @State private var presentedAttention: AttentionDestination?
    @State private var isShowingAllAttention = false
    @State private var activityStore: ActivityFeedStore

    public init(container: DependencyContainer, jumpToContext: @escaping (AppContext) -> Void, onTriggerCreate: @escaping () -> Void) {
        self.container = container
        self.jumpToContext = jumpToContext
        self.onTriggerCreate = onTriggerCreate
        _activityStore = State(initialValue: ActivityFeedStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            List {
                heroSection
                attentionSection
                continueSection
                activitySection
                toolsSection
            }
            .listStyle(.insetGrouped)
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

    // MARK: - 1. Hero greeting

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting + ",")
                    .font(.title2)
                    .foregroundStyle(Theme.Text.secondary)
                Text(container.currentActorStore.actor?.displayName ?? "Hola")
                    .font(.largeTitle.weight(.bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 16, leading: 4, bottom: 8, trailing: 4))
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Buenos días"
        case 12..<19: return "Buenas tardes"
        default:      return "Buenas noches"
        }
    }

    // MARK: - 2. Atención

    @ViewBuilder
    private var attentionSection: some View {
        let items = container.attentionInboxStore.items
        Section {
            if items.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo al día").font(.callout.weight(.medium))
                        Text("Sin pendientes en este momento")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
            } else {
                ForEach(items.prefix(3)) { item in
                    Button {
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    } label: {
                        attentionRow(item)
                    }
                }
                if items.count > 3 {
                    Button {
                        isShowingAllAttention = true
                    } label: {
                        Label("Ver todos los pendientes (\(items.count))", systemImage: "list.bullet")
                    }
                }
            }
        } header: {
            Text("Atención")
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: AttentionPresentation.symbol(for: item.kind))
                .foregroundStyle(priorityTint(item.derivedPriority))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(item.contextDisplayName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
    }

    private func priorityTint(_ priority: AttentionPriority) -> Color {
        switch priority {
        case .critical: return Theme.Tint.critical
        case .high:     return Theme.Tint.warning
        case .normal:   return Theme.Tint.info
        case .low:      return Theme.Text.tertiary
        }
    }

    // MARK: - 3. Continuar (carrusel horizontal embebido en row)

    @ViewBuilder
    private var continueSection: some View {
        let recents = container.contextPreferencesStore.recents
        let resolved = recents.compactMap { pref in
            container.contextStore.availableContexts.first { $0.id == pref.contextActorId }
        }
        if !resolved.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    // R.5V.Glass.C2 founder feedback — mismo tratamiento que
                    // "Espacios dentro de X" en ContextDetailViewV2: container
                    // de glass para que las cards hagan morph al scroll.
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            ForEach(resolved) { ctx in
                                continueCard(ctx)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .scrollTargetLayout()
                    }
                }
                .scrollTargetBehavior(.viewAligned)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Continuar")
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
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.Tint.primary)
                    .frame(width: 40, height: 40)
                    .background(Theme.Tint.primary.opacity(0.12), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                Spacer(minLength: 0)
                Text(ctx.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(ctx.isPersonal ? "Personal" : "\(ctx.memberCount) miembros")
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .frame(width: 160, height: 140, alignment: .topLeading)
            .padding(14)
            // R.5V.Glass.C2 founder feedback — Liquid Glass interactivo igual
            // que los children cards en ContextDetailViewV2.
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4. Actividad reciente

    @ViewBuilder
    private var activitySection: some View {
        let items = Array(activityStore.items.prefix(3))
        Section {
            if activityStore.phase.isLoading && activityStore.items.isEmpty {
                HStack {
                    ProgressView()
                    Text("Cargando…").foregroundStyle(Theme.Text.secondary)
                }
            } else if items.isEmpty {
                Text("Sin actividad reciente.")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(items, id: \.id) { item in
                    activityRow(item)
                }
                NavigationLink {
                    MyActivityFeedView(container: container)
                } label: {
                    Label("Ver toda la actividad", systemImage: "list.bullet")
                }
            }
        } header: {
            Text("Actividad reciente")
        }
    }

    @ViewBuilder
    private func activityRow(_ item: FeedItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(sourceColor(item.source).opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: item.asActivityEvent.symbolName)
                    .font(.callout)
                    .foregroundStyle(sourceColor(item.source))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.asActivityEvent.friendlyTitle(currentActorId: container.currentActorStore.actorId))
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
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
                .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceColor(_ source: FeedSource) -> Color {
        Theme.Source.tint(source)
    }

    private func contextName(for contextActorId: UUID?) -> String? {
        guard let id = contextActorId else { return nil }
        return container.contextStore.availableContexts.first { $0.id == id }?.displayName
    }

    // MARK: - 5. Herramientas (Próximamente)

    @ViewBuilder
    private var toolsSection: some View {
        Section {
            Label("Buscar", systemImage: "magnifyingglass")
            Label("Preguntar a Ruul", systemImage: "sparkles")
            Label("Escanear", systemImage: "qrcode.viewfinder")
        } header: {
            Text("Herramientas")
        } footer: {
            Text("Funciones que estamos desarrollando.")
        }
        .disabled(true)
    }
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
                                .font(.caption).foregroundStyle(Theme.Text.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
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
