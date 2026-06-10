import SwiftUI
import RuulCore

/// R.8.MiMundo.S7 — Vista cross-context del balance neto en dinero. Suma
/// obligaciones abiertas de tipo `money` cross-context y muestra:
///
/// 1. Total por moneda (hero chips: positivo = me deben, negativo = debo).
/// 2. Balance por contexto: row con el saldo neto agregado de ese contexto +
///    tap → `SettlementView(context)` para resolver.
///
/// Doctrina R.2N: el settlement neteado vivo es la fuente de verdad; iOS solo
/// agrega lo que ya está derivado en `obligations`. Los items con
/// `obligationKind != "money"` quedan fuera (los muestra MyObligationsView).
public struct MyBalanceView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var selectedContext: AppContext?

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando balance…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Mi balance neto")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selectedContext) { ctx in
            NavigationStack {
                SettlementView(context: ctx, container: container)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let myActorId = container.currentActorStore.actorId
        let totals = totalsByCurrency(myActorId: myActorId)
        let perContext = balancesByContext(myActorId: myActorId)

        List {
            totalsSection(totals)
            if perContext.isEmpty {
                emptySection
            } else {
                contextsSection(perContext)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func totalsSection(_ totals: [(currency: String, amount: Double)]) -> some View {
        Section {
            if totals.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "scalemass.fill")
                        .foregroundStyle(Theme.Tint.success)
                    Text("Estás a 0").font(.callout)
                        .foregroundStyle(Theme.Text.primary)
                }
                .padding(.vertical, Theme.Spacing.xs)
            } else {
                ForEach(totals, id: \.currency) { entry in
                    HStack {
                        Label(entry.currency, systemImage: "banknote.fill")
                            .foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Text(formattedAmount(entry.amount, currency: entry.currency))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(amountColor(entry.amount))
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Total por moneda")
        } footer: {
            Text("Positivo = te deben. Negativo = debes.")
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Tint.success)
                Text("Sin compromisos de dinero abiertos en tus contextos")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func contextsSection(_ rows: [ContextBalance]) -> some View {
        Section {
            ForEach(rows) { row in
                Button {
                    selectedContext = row.context
                } label: {
                    contextRow(row)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Por contexto")
        } footer: {
            Text("Toca un contexto para resolver el neteo con Settlement.")
        }
    }

    @ViewBuilder
    private func contextRow(_ row: ContextBalance) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.context.symbolName)
                .foregroundStyle(Theme.Tint.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.context.isPersonal ? "Mi espacio" : row.context.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(row.summaryText)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(row.totals, id: \.currency) { total in
                    Text(formattedAmount(total.amount, currency: total.currency))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(amountColor(total.amount))
                        .monospacedDigit()
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Text.tertiary)
        }
    }

    // MARK: - Aggregation

    private func totalsByCurrency(myActorId: UUID?) -> [(currency: String, amount: Double)] {
        var totals: [String: Double] = [:]
        for entry in aggregated where contributesToBalance(entry.obligation) {
            guard let currency = entry.obligation.currency, let amount = entry.obligation.amount else { continue }
            let signed = entry.obligation.debtorActorId == myActorId ? -amount : amount
            totals[currency, default: 0] += signed
        }
        return totals
            .filter { abs($0.value) > 0.005 }
            .map { (currency: $0.key, amount: $0.value) }
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    private func balancesByContext(myActorId: UUID?) -> [ContextBalance] {
        let byContext = Dictionary(grouping: aggregated.filter { contributesToBalance($0.obligation) },
                                   by: { $0.context })
        var rows: [ContextBalance] = []
        for (context, entries) in byContext {
            var perCurrency: [String: Double] = [:]
            var openCount = 0
            for entry in entries {
                guard let currency = entry.obligation.currency, let amount = entry.obligation.amount else { continue }
                let signed = entry.obligation.debtorActorId == myActorId ? -amount : amount
                perCurrency[currency, default: 0] += signed
                openCount += 1
            }
            let totals = perCurrency
                .filter { abs($0.value) > 0.005 }
                .map { (currency: $0.key, amount: $0.value) }
                .sorted { abs($0.amount) > abs($1.amount) }
            guard !totals.isEmpty else { continue }
            rows.append(ContextBalance(context: context, totals: totals, openCount: openCount))
        }
        return rows.sorted { abs($0.dominantAmount) > abs($1.dominantAmount) }
    }

    private func contributesToBalance(_ o: Obligation) -> Bool {
        guard o.isMoneyKind else { return false }
        return o.isOpen || o.status == "accepted" || o.status == "in_progress"
    }

    private func amountColor(_ amount: Double) -> Color {
        if amount > 0 { return Theme.Tint.success }
        if amount < 0 { return Theme.Tint.warning }
        return Theme.Text.secondary
    }

    private func formattedAmount(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
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

    private struct ContextBalance: Identifiable {
        let context: AppContext
        let totals: [(currency: String, amount: Double)]
        let openCount: Int
        var id: UUID { context.id }
        var dominantAmount: Double { totals.first?.amount ?? 0 }
        var summaryText: String {
            "\(openCount) compromiso\(openCount == 1 ? "" : "s") abierto\(openCount == 1 ? "" : "s")"
        }
    }
}

#Preview("Mi balance (demo)") {
    NavigationStack {
        MyBalanceView(container: .demo())
    }
}
