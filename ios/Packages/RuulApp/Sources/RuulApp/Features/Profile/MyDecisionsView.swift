import SwiftUI
import RuulCore

/// R.8.MiMundo.S4 — Vista cross-context de decisiones donde participo. Mismo
/// patrón que `MyObligationsView`: fan-out paralelo + filtro Activas/Cerradas.
///
/// P1.15 — el filtro "Por votar" cruza las decisiones abiertas con
/// `decision_votes` para mostrar solo las que esperan tu voto (y badge
/// "Te falta votar" en Activas). `attention_inbox().decision_vote` sigue
/// cubriendo la urgencia desde Home.
public struct MyDecisionsView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var filter: DecisionFilter = .toVote

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando decisiones…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Mis decisiones")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let filtered = aggregated
            .filter { matches(filter, entry: $0) }
            .sorted(by: closesAtAsc)

        List {
            filterSection
            if filtered.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(filtered) { entry in
                        NavigationLink {
                            DecisionDetailView(
                                decisionId: entry.decision.id,
                                context: entry.context,
                                container: container
                            )
                        } label: {
                            row(entry.decision, contextName: entry.context.displayName,
                                needsMyVote: entry.needsMyVote)
                        }
                    }
                } header: {
                    Label(filter.sectionLabel, systemImage: filter.sectionSymbol)
                        .foregroundStyle(filter == .closed ? Theme.Text.secondary : Color.purple)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("Filtro", selection: $filter) {
                ForEach(DecisionFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.md,
                                       bottom: Theme.Spacing.sm, trailing: Theme.Spacing.md))
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: filter == .closed ? "tray" : "checkmark.circle.fill")
                    .foregroundStyle(filter == .closed ? Theme.Text.tertiary : Theme.Tint.success)
                Text(filter.emptyLabel)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func row(_ d: Decision, contextName: String, needsMyVote: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.bubble.fill")
                .foregroundStyle(.purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(contextName).lineLimit(1)
                    if let closes = d.closesAt {
                        Text("·")
                        Text(d.isOpen ? "Cierra \(closes.formatted(date: .abbreviated, time: .shortened))"
                                       : closes.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(closingColor(closes, isOpen: d.isOpen))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 8)
            if needsMyVote {
                Text("Te falta votar")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple, in: Capsule())
            } else {
                Text(statusLabel(d))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTint(d))
            }
        }
    }

    private func closingColor(_ closes: Date, isOpen: Bool) -> Color {
        guard isOpen else { return Theme.Text.secondary }
        if closes < Date() { return Theme.Tint.critical }
        if closes.timeIntervalSinceNow < 86_400 { return Theme.Tint.warning }
        return Theme.Text.secondary
    }

    private func statusLabel(_ d: Decision) -> String {
        switch d.status {
        case "open":     return "Abierta"
        case "approved": return "Aprobada"
        case "rejected": return "Rechazada"
        case "executed": return "Ejecutada"
        case "cancelled": return "Cancelada"
        default:         return d.status.capitalized
        }
    }

    private func statusTint(_ d: Decision) -> Color {
        switch d.status {
        case "open":     return .purple
        case "approved": return Theme.Tint.success
        case "rejected": return Theme.Tint.critical
        case "executed": return Theme.Tint.info
        case "cancelled": return Theme.Text.tertiary
        default:         return Theme.Text.secondary
        }
    }

    private func closesAtAsc(_ a: Entry, _ b: Entry) -> Bool {
        (a.decision.closesAt ?? .distantFuture) < (b.decision.closesAt ?? .distantFuture)
    }

    // MARK: - Filter logic

    private func matches(_ filter: DecisionFilter, entry: Entry) -> Bool {
        switch filter {
        case .toVote:
            return entry.needsMyVote
        case .active:
            return entry.decision.status == "open"
        case .closed:
            return entry.decision.status != "open"
        }
    }

    // MARK: - Data

    private func load() async {
        if aggregated.isEmpty { phase = .loading }
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            aggregated = []
            phase = .loaded
            return
        }
        let myActorId = container.currentActorStore.actorId
        await withTaskGroup(of: ContextSlice.self) { group in
            for ctx in contexts {
                group.addTask {
                    let decisions: [Decision] = (try? await container.rpc.listDecisions(contextId: ctx.id)) ?? []
                    // P1.15 — para las abiertas, ¿ya voté? (tolerante a fallos:
                    // sin votos cargados se asume que falta mi voto solo si open).
                    var votedIds: Set<UUID> = []
                    for d in decisions where d.isOpen {
                        let votes = (try? await container.rpc.listDecisionVotes(decisionId: d.id)) ?? []
                        if votes.contains(where: { $0.voterActorId == myActorId }) {
                            votedIds.insert(d.id)
                        }
                    }
                    return ContextSlice(context: ctx, decisions: decisions, votedIds: votedIds)
                }
            }
            var all: [Entry] = []
            for await slice in group {
                for d in slice.decisions {
                    all.append(Entry(
                        decision: d,
                        context: slice.context,
                        needsMyVote: d.isOpen && !slice.votedIds.contains(d.id)
                    ))
                }
            }
            aggregated = all
        }
        phase = .loaded
    }

    // MARK: - Types

    private struct Entry: Identifiable, Sendable {
        let decision: Decision
        let context: AppContext
        let needsMyVote: Bool
        var id: UUID { decision.id }
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let decisions: [Decision]
        let votedIds: Set<UUID>
    }

    private enum DecisionFilter: String, CaseIterable, Identifiable {
        case toVote, active, closed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .toVote: return "Por votar"
            case .active: return "Activas"
            case .closed: return "Cerradas"
            }
        }
        var sectionLabel: String {
            switch self {
            case .toVote: return "Esperan tu voto"
            case .active: return "Abiertas"
            case .closed: return "Cerradas"
            }
        }
        var sectionSymbol: String {
            switch self {
            case .toVote: return "person.badge.clock"
            case .active: return "checkmark.bubble.fill"
            case .closed: return "archivebox.fill"
            }
        }
        var emptyLabel: String {
            switch self {
            case .toVote: return "Nada espera tu voto — al día"
            case .active: return "Sin decisiones abiertas"
            case .closed: return "Sin decisiones cerradas"
            }
        }
    }
}

#Preview("Mis decisiones (demo)") {
    NavigationStack {
        MyDecisionsView(container: .demo())
    }
}
