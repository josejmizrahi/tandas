import SwiftUI
import RuulCore

/// R.8.MiMundo.S3 — Vista cross-context de todos los compromisos donde yo
/// participo (debtor o creditor). Fan-out paralelo sobre `availableContexts`
/// + filtro Activos/Cerradas + secciones **Debo** / **Me deben**.
///
/// Sigue el mismo patrón de carga que `MyCalendarView`: `withTaskGroup` por
/// contexto, tolera fallos parciales (`try?`), y arma una lista flat con el
/// contexto adjunto para que `ObligationDetailView` reciba el `context` correcto.
public struct MyObligationsView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var filter: ObligationFilter = .active
    /// P2.1 — búsqueda por título o contexto.
    @State private var query: String = ""

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando compromisos…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Mis compromisos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let myActorId = container.currentActorStore.actorId
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        let filtered = aggregated
            .filter { matches(filter, status: $0.obligation.status) }
            .filter { entry in
                guard !trimmedQuery.isEmpty else { return true }
                return entry.obligation.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || entry.context.displayName.localizedCaseInsensitiveContains(trimmedQuery)
            }
        let debts = filtered
            .filter { $0.obligation.debtorActorId == myActorId }
            .sorted(by: dueAtAsc)
        let credits = filtered
            .filter {
                $0.obligation.creditorActorId == myActorId
                    && $0.obligation.debtorActorId != myActorId
            }
            .sorted(by: dueAtAsc)

        List {
            filterSection
            if debts.isEmpty && credits.isEmpty {
                emptySection
            } else {
                if !debts.isEmpty {
                    section(title: "Debo", systemImage: "arrow.up.right.circle.fill",
                            tint: Theme.Tint.warning, entries: debts, asDebtor: true)
                }
                if !credits.isEmpty {
                    section(title: "Me deben", systemImage: "arrow.down.left.circle.fill",
                            tint: Theme.Tint.success, entries: credits, asDebtor: false)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Buscar compromiso")
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("Filtro", selection: $filter) {
                ForEach(ObligationFilter.allCases) { option in
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
                Text(filter == .active ? "Sin compromisos abiertos" : "Sin compromisos cerrados")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func section(title: String, systemImage: String, tint: Color, entries: [Entry], asDebtor: Bool) -> some View {
        Section {
            ForEach(entries) { entry in
                NavigationLink {
                    ObligationDetailView(
                        obligationId: entry.obligation.id,
                        context: entry.context,
                        container: container
                    )
                } label: {
                    row(entry.obligation, contextName: entry.context.displayName, asDebtor: asDebtor)
                }
            }
        } header: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func row(_ o: Obligation, contextName: String, asDebtor: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: o.isMoneyKind ? "creditcard.fill" : "checklist")
                .foregroundStyle(asDebtor ? Theme.Tint.warning : Theme.Tint.success)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.title ?? o.typeLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(contextName).lineLimit(1)
                    if let due = o.dueAt {
                        Text("·")
                        Text("Vence \(due.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(dueColor(due))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = o.amount, let currency = o.currency {
                    Text(formattedAmount(amount, currency: currency))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(asDebtor ? Theme.Tint.warning : Theme.Tint.success)
                        .monospacedDigit()
                } else {
                    Text(o.kindLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Text.secondary)
                }
                Text(o.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
    }

    private func dueColor(_ due: Date) -> Color {
        // Vencido en rojo, próximo a vencer (≤ 24h) en warning, resto secondary.
        if due < Date() { return Theme.Tint.critical }
        if due.timeIntervalSinceNow < 86_400 { return Theme.Tint.warning }
        return Theme.Text.secondary
    }

    private func formattedAmount(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }

    private func dueAtAsc(_ a: Entry, _ b: Entry) -> Bool {
        (a.obligation.dueAt ?? .distantFuture) < (b.obligation.dueAt ?? .distantFuture)
    }

    // MARK: - Filter logic

    private func matches(_ filter: ObligationFilter, status: String) -> Bool {
        switch filter {
        case .active:
            switch status {
            case "open", "accepted", "in_progress", "disputed":
                return true
            default:
                return false
            }
        case .closed:
            switch status {
            case "completed", "settled", "forgiven", "cancelled", "expired":
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Data

    private func load() async {
        if aggregated.isEmpty { phase = .loading }
        let myActorId = container.currentActorStore.actorId
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            aggregated = []
            phase = .loaded
            return
        }
        await withTaskGroup(of: ContextSlice.self) { group in
            for ctx in contexts {
                group.addTask {
                    let obligations: [Obligation] = (try? await container.rpc.listObligations(contextId: ctx.id)) ?? []
                    return ContextSlice(context: ctx, obligations: obligations)
                }
            }
            var all: [Entry] = []
            for await slice in group {
                for o in slice.obligations where isMine(o, myActorId: myActorId) {
                    all.append(Entry(obligation: o, context: slice.context))
                }
            }
            aggregated = all
        }
        phase = .loaded
    }

    private func isMine(_ o: Obligation, myActorId: UUID?) -> Bool {
        guard let myActorId else { return false }
        return o.debtorActorId == myActorId || o.creditorActorId == myActorId
    }

    // MARK: - Types

    private struct Entry: Identifiable, Sendable {
        let obligation: Obligation
        let context: AppContext
        var id: UUID { obligation.id }
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let obligations: [Obligation]
    }

    private enum ObligationFilter: String, CaseIterable, Identifiable {
        case active, closed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .active: return "Activos"
            case .closed: return "Cerradas"
            }
        }
    }
}

#Preview("Mis compromisos (demo)") {
    NavigationStack {
        MyObligationsView(container: .demo())
    }
}
