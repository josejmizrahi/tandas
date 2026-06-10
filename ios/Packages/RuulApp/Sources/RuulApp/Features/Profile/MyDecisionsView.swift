import SwiftUI
import RuulCore

/// R.8.MiMundo.S4 — Vista cross-context de decisiones donde participo. Mismo
/// patrón que `MyObligationsView`: fan-out paralelo + filtro Activas/Cerradas.
///
/// Por ahora muestra TODAS las decisiones visibles del contexto (no filtra por
/// "ya voté"). El backend ya filtra por RLS lo que puedo ver; el refinamiento
/// "necesito votar todavía" requiere `listDecisionVotes` adicional y queda
/// como follow-up. Para urgencia, `attention_inbox().decision_vote` cubre los
/// votos pendientes prioritarios desde Home/Yo Atención.
public struct MyDecisionsView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var filter: DecisionFilter = .active

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
            .filter { matches(filter, status: $0.decision.status) }
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
                            row(entry.decision, contextName: entry.context.displayName)
                        }
                    }
                } header: {
                    Label(filter == .active ? "Abiertas" : "Cerradas",
                          systemImage: filter == .active ? "checkmark.bubble.fill" : "archivebox.fill")
                        .foregroundStyle(filter == .active ? Color.purple : Theme.Text.secondary)
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
                Image(systemName: filter == .active ? "checkmark.circle.fill" : "tray")
                    .foregroundStyle(filter == .active ? Theme.Tint.success : Theme.Text.tertiary)
                Text(filter == .active ? "Sin decisiones abiertas" : "Sin decisiones cerradas")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func row(_ d: Decision, contextName: String) -> some View {
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
            Text(statusLabel(d))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusTint(d))
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

    private func matches(_ filter: DecisionFilter, status: String) -> Bool {
        switch filter {
        case .active:
            return status == "open"
        case .closed:
            return status != "open"
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
        await withTaskGroup(of: ContextSlice.self) { group in
            for ctx in contexts {
                group.addTask {
                    let decisions: [Decision] = (try? await container.rpc.listDecisions(contextId: ctx.id)) ?? []
                    return ContextSlice(context: ctx, decisions: decisions)
                }
            }
            var all: [Entry] = []
            for await slice in group {
                for d in slice.decisions {
                    all.append(Entry(decision: d, context: slice.context))
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
        var id: UUID { decision.id }
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let decisions: [Decision]
    }

    private enum DecisionFilter: String, CaseIterable, Identifiable {
        case active, closed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .active: return "Activas"
            case .closed: return "Cerradas"
            }
        }
    }
}

#Preview("Mis decisiones (demo)") {
    NavigationStack {
        MyDecisionsView(container: .demo())
    }
}
