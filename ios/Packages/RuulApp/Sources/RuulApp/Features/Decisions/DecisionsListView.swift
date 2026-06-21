import SwiftUI
import RuulCore

/// F.10 — lista de decisiones del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native + Liquid Glass (mismo patrón
/// que MyResources/Events/Members/Rules v3):
/// 1. Hero Liquid Glass: count de abiertas + breakdown chips por status
/// 2. `.searchable` para filtrar por título / descripción
/// 3. Sections por status (Abiertas / Aprobadas / Rechazadas / Ejecutadas /
///    Canceladas) con tints semánticos
/// 4. Estados Ruul* (Loading/Error/Empty)
public struct DecisionsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DecisionsStore
    @State private var isShowingCreate = false
    @State private var query: String = ""
    /// R.5V.Zoom — Namespace para matched transition source → destination zoom.
    @Namespace private var zoomNamespace

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: DecisionsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando votaciones…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Votaciones")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            if store.canCreate(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Proponer", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            NavigationStack {
                CreateDecisionView(context: context, container: container)
            }
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private var loadedContent: some View {
        if store.decisions.isEmpty {
            RuulEmptyState(
                title: "Sin votaciones",
                systemImage: "checkmark.seal",
                message: "Propón algo y que el grupo vote: cambiar una regla, aprobar un gasto o resolver un conflicto."
            )
        } else {
            let filtered = filter(store.decisions)
            let grouped = groupByStatus(filtered)
            List {
                heroSection(store.decisions)
                ForEach(DecisionStatusGroup.displayOrder, id: \.self) { group in
                    if let items = grouped[group], !items.isEmpty {
                        Section {
                            ForEach(items) { decision in
                                decisionRow(decision, group: group)
                            }
                        } header: {
                            HStack {
                                Label(group.displayName, systemImage: group.symbolName)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Text("\(items.count)")
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
                if grouped.isEmpty {
                    Section {
                        Text("Sin coincidencias con \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar votación")
            .searchToolbarBehavior(.minimize)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ decisions: [Decision]) -> some View {
        let byGroup = Dictionary(grouping: decisions, by: { DecisionStatusGroup.from($0.status) })
        let breakdown = DecisionStatusGroup.displayOrder.compactMap { g -> (DecisionStatusGroup, Int)? in
            guard let count = byGroup[g]?.count, count > 0 else { return nil }
            return (g, count)
        }
        let openCount = byGroup[.open]?.count ?? 0
        Section {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(openCount)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(openCount > 0 ? .purple : Theme.Text.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(openCount == 1 ? "votación abierta" : "votaciones abiertas")
                                .font(.callout)
                                .foregroundStyle(Theme.Text.secondary)
                            if decisions.count > openCount {
                                Text("\(decisions.count - openCount) en historial")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if !breakdown.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.xs) {
                                ForEach(breakdown, id: \.0) { group, count in
                                    statusChip(group, count: count)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.lg, bottom: Theme.Spacing.md, trailing: Theme.Spacing.lg))
        }
    }

    @ViewBuilder
    private func statusChip(_ group: DecisionStatusGroup, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: group.symbolName)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(group.tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(group.tint.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Row

    @ViewBuilder
    private func decisionRow(_ decision: Decision, group: DecisionStatusGroup) -> some View {
        NavigationLink {
            DecisionDetailView(decisionId: decision.id, context: context, container: container)
                .navigationTransition(.zoom(sourceID: decision.id, in: zoomNamespace))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    Text(decision.type.label + " · " + store.displayName(for: decision.createdByActorId))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: group.symbolName)
                    .foregroundStyle(group.tint)
            }
        }
        .matchedTransitionSource(id: decision.id, in: zoomNamespace)
    }

    // MARK: - Filter + group

    private func filter(_ decisions: [Decision]) -> [Decision] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return decisions }
        return decisions.filter { d in
            d.title.lowercased().contains(q)
                || (d.description?.lowercased().contains(q) ?? false)
        }
    }

    private func groupByStatus(_ decisions: [Decision]) -> [DecisionStatusGroup: [Decision]] {
        Dictionary(grouping: decisions, by: { DecisionStatusGroup.from($0.status) })
            .mapValues { items in
                items.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            }
    }
}

// MARK: - DecisionStatusGroup

private enum DecisionStatusGroup: String, CaseIterable, Hashable {
    case open, approved, executed, rejected, cancelled

    static let displayOrder: [DecisionStatusGroup] = [.open, .approved, .executed, .rejected, .cancelled]

    static func from(_ status: String) -> DecisionStatusGroup {
        switch status {
        case "open":      return .open
        case "approved":  return .approved
        case "executed":  return .executed
        case "rejected":  return .rejected
        case "cancelled": return .cancelled
        default:          return .open
        }
    }

    var displayName: String {
        switch self {
        case .open:      return "Abiertas"
        case .approved:  return "Aprobadas"
        case .executed:  return "Ejecutadas"
        case .rejected:  return "Rechazadas"
        case .cancelled: return "Canceladas"
        }
    }

    var symbolName: String {
        switch self {
        case .open:      return "circle.dotted"
        case .approved:  return "checkmark.seal.fill"
        case .executed:  return "play.circle.fill"
        case .rejected:  return "xmark.seal.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .open:      return .purple                   // pending vote
        case .approved:  return Theme.Tint.success        // green
        case .executed:  return Theme.Tint.success
        case .rejected:  return Theme.Tint.critical       // red
        case .cancelled: return Theme.Text.tertiary       // muted
        }
    }
}

#Preview("Decisiones") {
    NavigationStack {
        DecisionsListView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
