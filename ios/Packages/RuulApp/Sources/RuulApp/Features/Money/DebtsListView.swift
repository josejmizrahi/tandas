import SwiftUI
import RuulCore

/// Full list of the caller's open obligations (Primitiva 19 +
/// `member_obligation_summary`). Split into two sections — "Con
/// miembros" (peer pairs) and "Con el grupo" (pool) — per
/// `doctrine_money_two_worlds`. Each row has a "Liquidar" affordance
/// that opens the existing `RecordSettlementSheet`.
struct DebtsListView: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID

    @State private var isShowingSettlement: Bool = false

    var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Debts.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettlement = true
                } label: {
                    Label(String(localized: L10n.Debts.liquidateButton), systemImage: "checkmark.circle")
                }
                .disabled(container.moneyStore.obligations.isEmpty)
            }
        }
        .sheet(isPresented: $isShowingSettlement) {
            RecordSettlementSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            ) {
                isShowingSettlement = false
                Task {
                    await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch container.moneyStore.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                placeholderRow
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Debts.errorTitle)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(String(localized: L10n.MoneyDashboard.retry)) {
                    Task {
                        await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
                    }
                }
            }
            .padding(.vertical, 6)
        case .loaded:
            if container.moneyStore.obligations.isEmpty {
                emptyState
            } else {
                if !memberObligations.isEmpty {
                    Section(L10n.Debts.withMembersSection) {
                        ForEach(memberObligations) { obligation in
                            obligationRow(obligation)
                        }
                    }
                }
                if !poolObligations.isEmpty {
                    Section(L10n.Debts.withPoolSection) {
                        ForEach(poolObligations) { obligation in
                            obligationRow(obligation)
                        }
                    }
                }
            }
        }
    }

    private var memberObligations: [ObligationSummary] {
        container.moneyStore.obligations.filter { $0.owedToKind == "member" }
    }

    private var poolObligations: [ObligationSummary] {
        container.moneyStore.obligations.filter { $0.owedToKind == "pool" }
    }

    @ViewBuilder
    private func obligationRow(_ obligation: ObligationSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.owedToLabel)
                    .font(.body)
                Text(obligation.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(obligation.amountOutstanding, format: .currency(code: "MXN"))
                .font(.body.monospacedDigit())
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Debts.emptyTitle).font(.headline)
            Text(L10n.Debts.emptyDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Placeholder").font(.body)
                Text("kind").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("$0.00").font(.body.monospacedDigit())
        }
        .redacted(reason: .placeholder)
    }
}
