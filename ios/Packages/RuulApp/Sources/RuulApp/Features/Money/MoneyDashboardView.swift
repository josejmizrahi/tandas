import SwiftUI
import RuulCore

/// Dedicated money surface for a single group. Replaces the embedded
/// `MoneyBlock` on `GroupHomeView` with a full page — hero balance +
/// pending monetary sanctions + debts summary + quick actions.
///
/// Pattern: Wallet card hero + grouped sections. Data comes from the
/// already-mounted `MoneyStore` (balance + obligations) and
/// `SanctionsStore` (filtered to monetary + this member); the dashboard
/// owns its own refresh trigger so it can be pushed independently.
///
/// Phase A2.a — read + pay paths only. Movements list, stake history
/// and pool charges (A2.b) wait on the `group_money_movements` RPC.
struct MoneyDashboardView: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID

    @State private var isShowingExpenseSheet: Bool = false
    @State private var isShowingSettlementSheet: Bool = false
    @State private var pendingPaySanction: GroupSanction?

    var body: some View {
        List {
            heroSection
            sanctionsSection
            debtsSection
            actionsSection
        }
        .navigationTitle(L10n.MoneyDashboard.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: DebtsDestination.self) { _ in
            DebtsListView(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            )
        }
        .refreshable {
            await refresh()
        }
        .task {
            await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
            await container.sanctionsStore.refreshIfNeeded(groupId: groupId)
        }
        .sheet(isPresented: $isShowingExpenseSheet) {
            RecordExpenseSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            ) {
                isShowingExpenseSheet = false
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $isShowingSettlementSheet) {
            RecordSettlementSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            ) {
                isShowingSettlementSheet = false
                Task { await refresh() }
            }
        }
        .sheet(item: $pendingPaySanction) { sanction in
            PaySanctionSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId,
                sanction: sanction
            ) {
                pendingPaySanction = nil
                Task { await refresh() }
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        Section {
            switch container.moneyStore.phase {
            case .idle, .loading:
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 24)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.MoneyDashboard.errorTitle)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: L10n.MoneyDashboard.retry)) {
                        Task { await refresh() }
                    }
                }
                .padding(.vertical, 6)
            case .loaded:
                heroCard
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } header: {
            Text(L10n.MoneyDashboard.groupSummary)
        }
    }

    @ViewBuilder
    private var heroCard: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(heroLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(heroAmount, format: .currency(code: "MXN"))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(heroColor)
        }
    }

    private var heroAmount: Decimal {
        container.moneyStore.balance ?? 0
    }

    private var heroLabel: LocalizedStringResource {
        guard let balance = container.moneyStore.balance else {
            return L10n.MoneyDashboard.heroEmptyLabel
        }
        if balance == 0 { return L10n.MoneyDashboard.heroZeroLabel }
        return balance > 0
            ? L10n.MoneyDashboard.heroPositiveLabel
            : L10n.MoneyDashboard.heroNegativeLabel
    }

    private var heroColor: Color {
        guard let balance = container.moneyStore.balance else { return .secondary }
        if balance == 0 { return .primary }
        return balance > 0 ? .green : .red
    }

    // MARK: - Sanctions to pay

    @ViewBuilder
    private var sanctionsSection: some View {
        let mine = monetarySanctionsToPay
        if !mine.isEmpty {
            Section(L10n.MoneyDashboard.sanctionsToPaySection) {
                ForEach(mine) { sanction in
                    Button {
                        pendingPaySanction = sanction
                    } label: {
                        sanctionRow(sanction)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var monetarySanctionsToPay: [GroupSanction] {
        container.sanctionsStore.sanctions.filter { sanction in
            sanction.targetMembershipId == myMembershipId
                && sanction.kind == .monetary
                && sanction.status.isOpen
        }
    }

    @ViewBuilder
    private func sanctionRow(_ sanction: GroupSanction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sanction.kind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(sanction.reason)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let amount = sanction.amount, let unit = sanction.unit {
                    Text("\(amount.formatted()) \(unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            Text(L10n.MoneyDashboard.paySanctionButton)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Debts

    @ViewBuilder
    private var debtsSection: some View {
        Section(L10n.MoneyDashboard.debtsSection) {
            if container.moneyStore.obligations.isEmpty,
               case .loaded = container.moneyStore.phase {
                Text(L10n.MoneyDashboard.debtsEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !container.moneyStore.obligations.isEmpty {
                NavigationLink(value: DebtsDestination()) {
                    HStack {
                        Text(debtsCountLabel)
                            .font(.body)
                        Spacer()
                    }
                }
            }
        }
    }

    private var debtsCountLabel: String {
        let count = container.moneyStore.obligations.count
        if count == 1 {
            return String(localized: L10n.MoneyDashboard.debtsCountSingular)
        }
        return "\(count) deudas abiertas"
    }

    // MARK: - Acciones

    @ViewBuilder
    private var actionsSection: some View {
        Section(L10n.MoneyDashboard.actionsSection) {
            Button {
                isShowingExpenseSheet = true
            } label: {
                Label(L10n.MoneyDashboard.actionRecordExpense, systemImage: "plus.circle")
            }
            Button {
                isShowingSettlementSheet = true
            } label: {
                Label(L10n.MoneyDashboard.actionSettle, systemImage: "checkmark.circle")
            }
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
        await container.sanctionsStore.refresh(groupId: groupId)
    }

    /// Hashable token for the dedicated debts surface (kept private so
    /// no other view can push into the dashboard's stack with the same
    /// type identity).
    private struct DebtsDestination: Hashable {}
}

/// One-line money summary used as the inline row on `GroupHomeView`
/// that pushes the full `MoneyDashboardView`. Renders balance + open
/// obligation count without the hero card chrome.
struct MoneySummaryRow: View {
    @Bindable var store: MoneyStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let balance = store.balance {
                Text(balance, format: .currency(code: "MXN"))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(balanceColor(balance))
            }
        }
    }

    private var headline: String {
        guard let balance = store.balance else { return "Sin posición todavía" }
        if balance == 0 { return "Estás al corriente" }
        return balance > 0 ? "El grupo te debe" : "Le debes al grupo"
    }

    private var subtitle: String {
        let count = store.obligations.count
        if count == 0 { return "Sin deudas abiertas" }
        if count == 1 { return "1 deuda abierta" }
        return "\(count) deudas abiertas"
    }

    private func balanceColor(_ balance: Decimal) -> Color {
        if balance == 0 { return .primary }
        return balance > 0 ? .green : .red
    }
}
