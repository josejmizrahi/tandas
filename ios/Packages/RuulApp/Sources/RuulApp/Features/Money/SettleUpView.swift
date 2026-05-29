import SwiftUI
import RuulCore

/// V3-SE-1 Splitwise-style "Settle up" surface. Reads
/// `MoneyStore.settlementPlan` (populated by
/// `group_settlement_plan_for_member`) and proposes a tap-to-settle
/// card per peer counterparty with a non-zero netted balance.
///
/// Tap a "Págale $X a Pedro" card → opens `RecordSettlementSheet`
/// prefilled with the counterparty + amount. Tap a "Pedro te debe $Y"
/// card → routes to the same sheet so the user can register that the
/// other person actually paid (doctrine: only direct counterparties
/// touch their own settlements; "marcar recibido" isn't a third-party
/// flow yet — explained in the empty/info section).
struct SettleUpView: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var presentedPrefill: RecordSettlementSheet.Prefill?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Saldar cuentas")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { dismiss() }
                    }
                }
                .task {
                    await container.moneyStore.refresh(
                        groupId: groupId,
                        membershipId: myMembershipId
                    )
                }
                .sheet(item: prefillBinding) { wrapper in
                    RecordSettlementSheet(
                        container: container,
                        groupId: groupId,
                        myMembershipId: myMembershipId,
                        prefill: wrapper.value,
                        onSubmitted: {
                            Task {
                                await container.moneyStore.refresh(
                                    groupId: groupId,
                                    membershipId: myMembershipId
                                )
                                presentedPrefill = nil
                            }
                        }
                    )
                }
        }
    }

    // Item-style binding for sheet(item:) since Prefill isn't Identifiable.
    // Map presence to a stable id-like wrapper so SwiftUI knows when to
    // (re)mount the sheet.
    private var prefillBinding: Binding<IdentifiablePrefill?> {
        Binding(
            get: { presentedPrefill.map(IdentifiablePrefill.init) },
            set: { presentedPrefill = $0?.value }
        )
    }

    private struct IdentifiablePrefill: Identifiable {
        let value: RecordSettlementSheet.Prefill
        var id: String {
            (value.counterpartyId?.uuidString ?? "pool")
                + ":" + (value.amount.map { "\($0)" } ?? "0")
        }
    }

    @ViewBuilder
    private var content: some View {
        let plan = container.moneyStore.settlementPlan
        if plan.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(plan) { item in
                        suggestionRow(for: item)
                    }
                } header: {
                    Text("Sugerencias")
                } footer: {
                    Text("Estos pagos saldan las deudas con cada persona en una sola transferencia. Tocaste un solo botón en vez de varios.")
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Estás a mano")
                .font(.title3.weight(.semibold))
            Text("No hay deudas pendientes con nadie del grupo en este momento.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func suggestionRow(for item: SettlementPlanItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: directionIconName(for: item))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(for: item))
                        .font(.body.weight(.semibold))
                    Text(subtitle(for: item))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatted(item.absoluteAmount, unit: item.unit))
                    .monospacedDigit()
                    .font(.body.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleTap(_ item: SettlementPlanItem) {
        switch item.direction {
        case .youOwe:
            presentedPrefill = .member(
                id: item.counterpartyMembershipId,
                label: item.counterpartyDisplayName,
                amount: item.absoluteAmount
            )
        case .theyOwe:
            // The caller can't register a settlement *from* the
            // counterparty on their behalf (no mandate flow surfaced
            // here). Open the sheet prefilled with the counterparty so
            // the user can still use it as a record of the conversation,
            // or treat it as a no-op nudge.
            presentedPrefill = .member(
                id: item.counterpartyMembershipId,
                label: item.counterpartyDisplayName,
                amount: nil
            )
        }
    }

    private func headline(for item: SettlementPlanItem) -> String {
        switch item.direction {
        case .youOwe:
            return "Págale a \(item.counterpartyDisplayName)"
        case .theyOwe:
            return "\(item.counterpartyDisplayName) te debe"
        }
    }

    private func subtitle(for item: SettlementPlanItem) -> String {
        switch item.direction {
        case .youOwe:
            return "Cierra todas tus deudas con esta persona en un solo pago."
        case .theyOwe:
            return "Cuando te pague, marca el monto como recibido."
        }
    }

    private func directionIconName(for item: SettlementPlanItem) -> String {
        switch item.direction {
        case .youOwe:  return "arrow.up.right.circle.fill"
        case .theyOwe: return "arrow.down.left.circle.fill"
        }
    }

    private func formatted(_ value: Decimal, unit: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = unit
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: value as NSNumber) ?? "\(value)"
    }
}
