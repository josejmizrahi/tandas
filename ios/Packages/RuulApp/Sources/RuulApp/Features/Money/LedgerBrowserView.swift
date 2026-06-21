import SwiftUI
import RuulCore

/// P1.9 — Browser de ledger: lista `money_transactions` del contexto (lectura)
/// + acción admin `void_transaction`. Desbloquea la anulación de transacciones,
/// que antes no tenía superficie (no había lista de transacciones individuales).
///
/// Gateado por backend: el void aparece sólo para el creador o quien tiene
/// `money.settle`, y nunca para liquidaciones (se revierten por el handshake).
public struct LedgerBrowserView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: LedgerStore
    @State private var runner = ActionRunner()
    @State private var pendingVoid: MoneyTransaction?
    @State private var voidReason: String = ""

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: LedgerStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulSkeletonList()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Movimientos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(context: context) }
        .refreshable { await store.load(context: context) }
        .actionErrorAlert(runner)
        .alert("Anular movimiento", isPresented: voidAlertBinding, presenting: pendingVoid) { txn in
            TextField("Motivo (opcional)", text: $voidReason)
            Button("Anular", role: .destructive) {
                Task { await performVoid(txn) }
            }
            Button("Cancelar", role: .cancel) { voidReason = "" }
        } message: { txn in
            Text("Se revierte \(txn.typeLabel.lowercased()) de \(txn.amount.currencyLabel(txn.currency)) y se cancelan las obligaciones abiertas ligadas. No se puede deshacer.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.transactions.isEmpty {
            RuulEmptyState(
                title: "Sin movimientos",
                systemImage: "list.bullet.rectangle",
                message: "Aquí aparecen los gastos, pagos, liquidaciones y resultados de juego del grupo."
            )
        } else {
            List {
                if !store.posted.isEmpty {
                    Section {
                        ForEach(store.posted) { txn in row(txn) }
                    } header: {
                        Text("Movimientos (\(store.posted.count))")
                    } footer: {
                        Text("Toca un movimiento para anularlo si tienes permiso.")
                    }
                }
                if !store.voided.isEmpty {
                    Section("Anulados (\(store.voided.count))") {
                        ForEach(store.voided) { txn in row(txn) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func row(_ txn: MoneyTransaction) -> some View {
        let voidable = store.canVoid(txn, in: context)
        Group {
            if voidable {
                Button {
                    voidReason = ""
                    pendingVoid = txn
                } label: { rowBody(txn) }
                .buttonStyle(.plain)
            } else {
                rowBody(txn)
            }
        }
    }

    @ViewBuilder
    private func rowBody(_ txn: MoneyTransaction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(txn))
                .foregroundStyle(txn.isVoided ? Theme.Text.tertiary : Theme.Tint.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(txn))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(txn.isVoided ? Theme.Text.secondary : Theme.Text.primary)
                    .lineLimit(1)
                    .strikethrough(txn.isVoided, color: Theme.Text.tertiary)
                Text(subtitle(txn))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(txn.amount.currencyLabel(txn.currency))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(txn.isVoided ? Theme.Text.tertiary : Theme.Text.primary)
                    .strikethrough(txn.isVoided, color: Theme.Text.tertiary)
                if let date = txn.occurredAt {
                    Text(date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Derivados

    private func title(_ txn: MoneyTransaction) -> String {
        let from = store.displayName(for: txn.fromActorId, contextId: context.id)
        let to = store.displayName(for: txn.toActorId, contextId: context.id)
        if txn.fromActorId == nil { return to }
        if txn.toActorId == nil { return from }
        return "\(from) → \(to)"
    }

    private func subtitle(_ txn: MoneyTransaction) -> String {
        var parts: [String] = [txn.typeLabel]
        if let note = txn.note { parts.append(note) }
        if txn.isVoided {
            if let reason = txn.voidReason { parts.append("Anulado: \(reason)") }
            else { parts.append("Anulado") }
        }
        return parts.joined(separator: " · ")
    }

    private func icon(_ txn: MoneyTransaction) -> String {
        switch txn.transactionType {
        case "expense": return "cart.fill"
        case "payment": return "creditcard.fill"
        case "settlement": return "arrow.left.arrow.right"
        case "contribution": return "arrow.down.circle.fill"
        case "payout": return "arrow.up.circle.fill"
        case "game_result": return "dice.fill"
        default: return "circle.fill"
        }
    }

    private var voidAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingVoid != nil },
            set: { if !$0 { pendingVoid = nil } }
        )
    }

    private func performVoid(_ txn: MoneyTransaction) async {
        let reason = voidReason.trimmingCharacters(in: .whitespaces)
        await runner.run {
            _ = try await store.void(txn, reason: reason.isEmpty ? nil : reason, context: context)
        }
        voidReason = ""
        pendingVoid = nil
    }
}

#Preview("Ledger") {
    NavigationStack {
        LedgerBrowserView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal"
            ),
            container: .demo()
        )
    }
}
