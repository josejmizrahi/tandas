import SwiftUI
import RuulCore

// MARK: - Dinero del evento (sección unificada)
//
// Founder 2026-06-12 "quiero ver todo organizado: gastos de ese evento, pools,
// votaciones, reglas, miembros" — antes el CTA "Registrar gasto"
// (R.5Z.fix.EVENT.1) y la lista de gastos reales (insights 2026-06-12) eran
// DOS secciones separadas. Ahora es una sola: gastos del evento (obligations
// con `source_event_id = event.id`) + total + CTA al final.
//
// P0.5 — el CTA renderiza vía `ActionMenuButton`: si record_expense viene
// disabled del backend se muestra deshabilitado con su `reason`, no desaparece.

struct EventDetailMoneySection: View {
    let eventId: UUID
    let context: AppContext
    let container: DependencyContainer
    let store: EventDetailStore
    let onRecordExpense: () -> Void

    @State private var obligations: [Obligation] = []
    @State private var didLoad = false

    private var recordExpenseAction: AvailableAction? {
        store.availableActions.first { $0.actionKey == "record_expense" }
    }

    var body: some View {
        if recordExpenseAction != nil || !obligations.isEmpty {
            // R.10.G.4 — header trailing "Ver todos" → LedgerBrowserView del
            // contexto (no event-filtered — el ledger global incluye todos los
            // gastos del espacio).
            Section {
                ForEach(Array(obligations.prefix(3))) { obligation in
                    NavigationLink {
                        ObligationDetailView(obligationId: obligation.id, context: context, container: container)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "banknote")
                                .foregroundStyle(Theme.Tint.success)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(obligation.title ?? "Gasto")
                                    .font(.callout)
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                Text(obligationSubtitle(obligation))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                            if let amount = obligation.amount, let currency = obligation.currency {
                                Text(amount, format: .currency(code: currency))
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(obligation.status == "settled" || obligation.status == "completed"
                                                     ? Theme.Text.tertiary : Theme.Text.primary)
                            }
                        }
                    }
                }
                if let action = recordExpenseAction {
                    ActionMenuButton(action: action) {
                        onRecordExpense()
                    }
                }
            } header: {
                HStack {
                    Text(obligations.isEmpty
                         ? "Dinero del evento"
                         : "Dinero del evento (\(obligations.count))")
                    Spacer()
                    if obligations.count > 3 {
                        NavigationLink {
                            LedgerBrowserView(context: context, container: container)
                        } label: {
                            HStack(spacing: 2) {
                                Text("Ver todos")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.Tint.primary)
                        }
                        .font(.subheadline.weight(.regular))
                    }
                }
                .textCase(nil)
            } footer: {
                footerText
            }
        } else if !didLoad {
            // Loader invisible SOLO mientras carga — evita el gap fantasma de una
            // sección implícita en cada evento. Al cargar y quedar vacío no
            // renderiza nada (antes el Color.clear vivía siempre fuera del if).
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .task { await loadIfNeeded() }
        }
    }

    @ViewBuilder
    private var footerText: some View {
        if let total = totalLabel {
            Text("Total repartido: \(total)")
        } else if recordExpenseAction?.enabled == true {
            Text("El gasto se divide automáticamente entre los participantes del evento.")
        }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        let all = (try? await container.rpc.listObligations(contextId: context.id)) ?? []
        obligations = all
            .filter { $0.sourceEventId == eventId }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private func obligationSubtitle(_ o: Obligation) -> String {
        let debtor = container.currentActorStore.actorId == o.debtorActorId ? "Tú" : "Miembro"
        switch o.status {
        case "settled", "completed": return "\(debtor) · liquidado"
        case "forgiven": return "\(debtor) · condonado"
        default: return "\(debtor) · pendiente"
        }
    }

    private var totalLabel: String? {
        guard let currency = obligations.first?.currency else { return nil }
        let total = obligations.compactMap(\.amount).reduce(0, +)
        guard total > 0 else { return nil }
        return total.formatted(.currency(code: currency))
    }
}
