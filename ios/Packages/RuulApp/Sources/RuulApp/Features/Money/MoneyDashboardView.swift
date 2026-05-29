import SwiftUI
import RuulCore

/// Dedicated money surface for a single group. Owns the Dinero tab —
/// hero balance + pending monetary sanctions + debts summary + quick
/// actions.
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
    @State private var isShowingSettleUp: Bool = false
    @State private var pendingPaySanction: GroupSanction?

    var body: some View {
        List {
            heroSection
            peerPairsSection
            sanctionsSection
            debtsSection
            movementsSection
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
        .navigationDestination(for: MovementsDestination.self) { _ in
            MoneyMovementsListView(
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
            await container.movementsStore.refreshIfNeeded(groupId: groupId)
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
        .sheet(isPresented: $isShowingSettleUp) {
            SettleUpView(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            )
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

    // MARK: - Entre miembros (V3 Batch B-2)

    /// Doctrina `doctrine_money_two_worlds`: el dashboard debe partir en
    /// "Con el grupo" (pool side) y "Entre miembros" (peer pairs). El
    /// hero + sanctions + debtsSection cubren la parte pool; esta
    /// sección surface las relaciones peer-to-peer del caller sin que
    /// tenga que abrir SettleUpView para verlas.
    ///
    /// Renders top 3 contrapartes por |netAmount| con vocab que nombra
    /// la contraparte ("Págale a {nombre}" / "{nombre} te debe").
    /// Tap → SettleUpView (existing surface) con la lista completa.
    /// Invisible si no hay peer pairs activos.
    @ViewBuilder
    private var peerPairsSection: some View {
        let plan = container.moneyStore.settlementPlan
        if !plan.isEmpty {
            Section {
                ForEach(plan.prefix(3)) { item in
                    Button {
                        isShowingSettleUp = true
                    } label: {
                        peerPairRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                if plan.count > 3 {
                    Button {
                        isShowingSettleUp = true
                    } label: {
                        Text("Ver todas (\(plan.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Entre miembros")
            }
        }
    }

    @ViewBuilder
    private func peerPairRow(item: SettlementPlanItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .youOwe
                  ? "arrow.up.right.circle.fill"
                  : "arrow.down.left.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(item.direction == .youOwe ? .red : .green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(peerPairHeadline(item))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(item.absoluteAmount.formatted()) \(item.unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// Mismo vocabulario que SettleUpView/MemberDetailView para que el
    /// usuario nunca dude qué significa una cifra.
    private func peerPairHeadline(_ item: SettlementPlanItem) -> String {
        switch item.direction {
        case .youOwe:  return "Págale a \(item.counterpartyDisplayName)"
        case .theyOwe: return "\(item.counterpartyDisplayName) te debe"
        }
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
        let openObligationIds = Set(container.moneyStore.obligations.map(\.id))
        return container.sanctionsStore.sanctions.filter { sanction in
            guard sanction.targetMembershipId == myMembershipId,
                  sanction.kind == .monetary,
                  sanction.status.isOpen
            else { return false }
            // `group_sanctions_active` keeps a row in `.active` even after
            // its linked obligation is settled — so cross-reference with
            // the caller's open obligations. Sanctions without a linked
            // obligation row (legacy/unusual) stay visible; sanctions
            // whose obligation is no longer outstanding drop out.
            if let oid = sanction.obligationId {
                return openObligationIds.contains(oid)
            }
            return true
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

    // MARK: - Debts (split por doctrine_money_two_worlds)

    /// Doctrina: el caller debe poder ver de un vistazo qué le debe AL
    /// GRUPO (multas, buy-ins, pool charges) y qué le debe A MIEMBROS
    /// específicos — no son la misma deuda social. Pre-PARTE B-2 esto
    /// era una sola línea "N deudas abiertas" que mezclaba todo.
    ///
    /// Pool side viene de obligations con `owedToKind == "pool"`.
    /// Peer side viene del settlementPlan (ya netted, excluye pool por
    /// doctrina), filtrado a direction == .youOwe para mostrar lo que
    /// efectivamente DEBES (los que te deben se ven en peerPairsSection).
    @ViewBuilder
    private var debtsSection: some View {
        let pool = poolObligations
        let peerDebts = peerOwedAmount
        let isLoaded: Bool = {
            if case .loaded = container.moneyStore.phase { return true }
            return false
        }()
        let allEmpty = pool.isEmpty && peerDebts == nil
        if !allEmpty || isLoaded {
            Section(L10n.MoneyDashboard.debtsSection) {
                if !pool.isEmpty {
                    NavigationLink(value: DebtsDestination()) {
                        HStack(spacing: 12) {
                            Image(systemName: "building.columns")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Con el grupo")
                                    .font(.body.weight(.medium))
                                Text(poolSummary(for: pool))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let totalOwed = peerDebts {
                    Button {
                        isShowingSettleUp = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Entre miembros")
                                    .font(.body.weight(.medium))
                                Text(totalOwed)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if pool.isEmpty, peerDebts == nil {
                    Text(L10n.MoneyDashboard.debtsEmpty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var poolObligations: [ObligationSummary] {
        container.moneyStore.obligations.filter { $0.owedToKind == "pool" }
    }

    private func poolSummary(for pool: [ObligationSummary]) -> String {
        let total = pool.reduce(Decimal(0)) { $0 + $1.amountOutstanding }
        if pool.count == 1 {
            return "\(total.formatted()) MXN"
        }
        return "\(pool.count) pendientes · \(total.formatted()) MXN"
    }

    /// Total que el caller debe NET a peers. Cuenta solo direction =
    /// .youOwe (lo que te deben es buena noticia, no debt section). nil
    /// cuando no hay deudas activas con miembros.
    private var peerOwedAmount: String? {
        let owed = container.moneyStore.settlementPlan
            .filter { $0.direction == .youOwe }
        guard !owed.isEmpty else { return nil }
        let total = owed.reduce(Decimal(0)) { $0 + $1.absoluteAmount }
        let unit = owed.first?.unit ?? "MXN"
        if owed.count == 1, let peer = owed.first {
            return "Págale a \(peer.counterpartyDisplayName) · \(total.formatted()) \(unit)"
        }
        return "\(owed.count) personas · \(total.formatted()) \(unit)"
    }

    // MARK: - Movements (recent + link to full list)

    @ViewBuilder
    private var movementsSection: some View {
        Section(L10n.MoneyMovements.title) {
            let recent = Array(container.movementsStore.movements.prefix(3))
            if recent.isEmpty, case .loaded = container.movementsStore.phase {
                Text(L10n.MoneyMovements.emptyDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !recent.isEmpty {
                ForEach(recent) { movement in
                    NavigationLink(value: MovementsDestination()) {
                        MoneyMovementCompactRow(movement: movement)
                    }
                }
                NavigationLink(value: MovementsDestination()) {
                    Text(viewAllMovementsLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var viewAllMovementsLabel: String {
        let count = container.movementsStore.movements.count
        guard count > 3 else { return String(localized: L10n.MoneyDashboard.debtsViewAll) }
        return "Ver todos (\(count))"
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
                isShowingSettleUp = true
            } label: {
                Label("Saldar cuentas", systemImage: "sparkles")
            }
            .disabled(container.moneyStore.settlementPlan.isEmpty)
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
        await container.movementsStore.refresh(groupId: groupId)
    }

    /// Hashable token for the dedicated debts surface (kept private so
    /// no other view can push into the dashboard's stack with the same
    /// type identity).
    private struct DebtsDestination: Hashable {}

    /// Same pattern for the movements list (A2.b).
    private struct MovementsDestination: Hashable {}
}

/// Compact one-line movement row used inside the dashboard's
/// "Movimientos recientes" preview. Full row formatting lives on
/// `MoneyMovementsListView`.
private struct MoneyMovementCompactRow: View {
    let movement: MoneyMovement

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: movement.type.systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(movement.headline)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(movement.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(movement.amount.formatted()) \(movement.unit)")
                .font(.subheadline.monospacedDigit())
                .strikethrough(movement.isReversal)
        }
    }
}

