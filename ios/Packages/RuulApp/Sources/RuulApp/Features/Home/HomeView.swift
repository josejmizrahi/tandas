import SwiftUI
import RuulCore

/// F.NAV.9 — Home rebuild con Apple HIG en mente.
///
/// Doctrina F.NAV:
/// - Sección 1: hero greeting + atención (card destacada).
/// - Sección 2: Continuar (carrusel horizontal de contextos recientes).
/// - Sección 3: Acciones globales (grid 2x2).
/// - Sección 4: Mi actividad (link).
public struct HomeView: View {
    let container: DependencyContainer
    let jumpToContext: (AppContext) -> Void
    let onTriggerCreate: () -> Void

    @State private var presentedAttention: AttentionItem?
    @State private var isShowingPendingInvitations = false
    @State private var isShowingAllAttention = false

    public init(container: DependencyContainer, jumpToContext: @escaping (AppContext) -> Void, onTriggerCreate: @escaping () -> Void) {
        self.container = container
        self.jumpToContext = jumpToContext
        self.onTriggerCreate = onTriggerCreate
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    heroSection
                    attentionSection
                    continueSection
                    quickActionsGrid
                    activitySection
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle("Ruul")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
            }
            .refreshable {
                await container.attentionInboxStore.load()
                await container.contextPreferencesStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
            }
            .sheet(item: $presentedAttention) { item in
                attentionDestination(for: item)
            }
            .sheet(isPresented: $isShowingPendingInvitations) {
                PendingInvitationsView(container: container)
            }
            .sheet(isPresented: $isShowingAllAttention) {
                NavigationStack {
                    AllAttentionView(container: container) { item in
                        isShowingAllAttention = false
                        handleTap(item)
                    }
                }
            }
        }
    }

    // MARK: - Sección 1: hero greeting

    @ViewBuilder
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting + ",")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(container.currentActorStore.actor?.displayName ?? "Hola")
                .font(.largeTitle.weight(.bold))
            Text(attentionSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Buenos días"
        case 12..<19: return "Buenas tardes"
        default:      return "Buenas noches"
        }
    }

    private var attentionSubtitle: String {
        let count = container.attentionInboxStore.items.count
        switch count {
        case 0: return "Todo está al día 🎉"
        case 1: return "1 cosa requiere tu atención"
        default: return "\(count) cosas requieren tu atención"
        }
    }

    // MARK: - Sección 2: Atención (card hero)

    @ViewBuilder
    private var attentionSection: some View {
        let items = container.attentionInboxStore.items
        if !items.isEmpty {
            Button {
                if items.count == 1 {
                    handleTap(items[0])
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
                        Text(items.count == 1 ? "Ver →" : "Ver \(items.count) →")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider().padding(.leading, 16)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.prefix(3)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: attentionSymbol(for: item.kind))
                                    .font(.callout)
                                    .foregroundStyle(attentionTint(for: item.kind))
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
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sección 3: Continuar (carrusel horizontal)

    @ViewBuilder
    private var continueSection: some View {
        let recents = container.contextPreferencesStore.recents
        let resolved = recents.compactMap { pref in
            container.contextStore.availableContexts.first { $0.id == pref.contextActorId }
        }
        if !resolved.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Continuar")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(resolved) { ctx in
                            continueCard(ctx)
                        }
                    }
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
                    .font(.title)
                    .foregroundStyle(.tint)
                Text(ctx.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !ctx.isPersonal {
                    Text("\(ctx.memberCount) miembros")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 140, alignment: .topLeading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sección 4: Acciones globales (grid 2x2)

    @ViewBuilder
    private var quickActionsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        VStack(alignment: .leading, spacing: 12) {
            Text("Acciones rápidas")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                actionTile(label: "Crear", icon: "plus.circle.fill", tint: .accentColor, enabled: true) {
                    onTriggerCreate()
                }
                actionTile(label: "Buscar", icon: "magnifyingglass", tint: .gray, enabled: false, action: {})
                actionTile(label: "Preguntar a Ruul", icon: "sparkles", tint: .gray, enabled: false, action: {})
                actionTile(label: "Escanear", icon: "qrcode.viewfinder", tint: .gray, enabled: false, action: {})
            }
        }
    }

    @ViewBuilder
    private func actionTile(label: String, icon: String, tint: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(enabled ? tint : Color.secondary)
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                if !enabled {
                    Text("Próximamente")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Sección 5: Mi actividad

    @ViewBuilder
    private var activitySection: some View {
        NavigationLink {
            MyActivityFeedView(container: container)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mi actividad").font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text("Lo que está pasando en los contextos que sigues")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Routing de atención

    private func appContext(for contextActorId: UUID) -> AppContext? {
        container.contextStore.availableContexts.first { $0.id == contextActorId }
    }

    private func handleTap(_ item: AttentionItem) {
        switch item.kind {
        case "invitation":
            isShowingPendingInvitations = true
        case "reservation_conflict":
            if let ctx = appContext(for: item.contextActorId) {
                jumpToContext(ctx)
            }
        case "decision_vote", "obligation_pay", "obligation_complete":
            presentedAttention = item
        default:
            break
        }
    }

    @ViewBuilder
    private func attentionDestination(for item: AttentionItem) -> some View {
        if let ctx = appContext(for: item.contextActorId) {
            NavigationStack {
                switch item.kind {
                case "decision_vote":
                    DecisionDetailView(
                        decisionId: item.ctaScopeId,
                        context: ctx,
                        container: container
                    )
                case "obligation_pay", "obligation_complete":
                    ObligationDetailView(
                        obligationId: item.ctaScopeId,
                        context: ctx,
                        container: container
                    )
                default:
                    EmptyView()
                }
            }
        }
    }

    private func attentionSymbol(for kind: String) -> String {
        switch kind {
        case "reservation_conflict": return "exclamationmark.triangle.fill"
        case "decision_vote":        return "hand.thumbsup.fill"
        case "obligation_pay":       return "creditcard.fill"
        case "obligation_complete":  return "checkmark.circle"
        case "invitation":           return "envelope.fill"
        default:                     return "circle.fill"
        }
    }

    private func attentionTint(for kind: String) -> Color {
        switch kind {
        case "reservation_conflict": return .red
        case "decision_vote":        return .purple
        case "obligation_pay",
             "obligation_complete":  return .green
        case "invitation":           return .blue
        default:                     return .secondary
        }
    }
}

// MARK: - Sheet "Todos los pendientes"

/// F.NAV.9 — Lista expandida de los items de atención. Se invoca cuando hay
/// más de uno y el founder tapea el hero "Ver N →".
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
                        Image(systemName: attentionSymbol(for: item.kind))
                            .foregroundStyle(attentionTint(for: item.kind))
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

    private func attentionSymbol(for kind: String) -> String {
        switch kind {
        case "reservation_conflict": return "exclamationmark.triangle.fill"
        case "decision_vote":        return "hand.thumbsup.fill"
        case "obligation_pay":       return "creditcard.fill"
        case "obligation_complete":  return "checkmark.circle"
        case "invitation":           return "envelope.fill"
        default:                     return "circle.fill"
        }
    }

    private func attentionTint(for kind: String) -> Color {
        switch kind {
        case "reservation_conflict": return .red
        case "decision_vote":        return .purple
        case "obligation_pay",
             "obligation_complete":  return .green
        case "invitation":           return .blue
        default:                     return .secondary
        }
    }
}

#Preview("Home (demo)") {
    HomeView(container: .demo(), jumpToContext: { _ in }, onTriggerCreate: {})
}
