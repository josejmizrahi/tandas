import SwiftUI
import RuulCore

/// Embedded view that surfaces the caller's money state inside a group:
/// balance scalar + list of open obligations. Lives inside `GroupHomeView`
/// for slice 4b; the parent owns the refresh trigger (so we can compose
/// it next to other blocks later without each block fighting for the
/// network).
struct MoneyBlock: View {
    let container: DependencyContainer

    var body: some View {
        Group {
            switch container.moneyStore.phase {
            case .idle, .loading:
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 16)
                    Spacer()
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("No pudimos cargar tu dinero", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded:
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            balanceRow
            if container.moneyStore.obligations.isEmpty {
                Text("No tienes deudas abiertas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deudas abiertas")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(container.moneyStore.obligations) { row in
                        ObligationRow(obligation: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var balanceRow: some View {
        if let balance = container.moneyStore.balance {
            VStack(alignment: .leading, spacing: 2) {
                Text(balanceLabel(for: balance))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(balance, format: .currency(code: "MXN"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(balance == 0 ? .primary : (balance > 0 ? Color.green : Color.red))
            }
        } else {
            Text("Sin posición")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func balanceLabel(for balance: Decimal) -> String {
        if balance == 0 { return "Estás al corriente con el grupo" }
        if balance > 0 { return "El grupo te debe" }
        return "Le debes al grupo"
    }
}

private struct ObligationRow: View {
    let obligation: ObligationSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.owedToLabel)
                    .font(.body)
                Text(obligation.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(obligation.amountOutstanding, format: .currency(code: "MXN"))
                .font(.body.monospacedDigit())
        }
    }
}
