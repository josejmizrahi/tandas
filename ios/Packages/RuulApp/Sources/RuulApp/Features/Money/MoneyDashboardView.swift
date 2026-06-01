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
    @State private var isShowingContribute: Bool = false
    @State private var isShowingPoolCharge: Bool = false
    @State private var pendingPaySanction: GroupSanction?
    /// V3 — pool balance del grupo, hidratado on appear.
    @State private var poolBalance: GroupPoolBalance?
    /// D.22 audit — caller perms, used to gate the "Cobrar cuota" chip
    /// (requires `pool_charge.record`, admin-only by default).
    @State private var permissionKeys: [String]? = nil

    var body: some View {
        List {
            heroSection
            poolBalanceSection
            quickActionsRow
            peerPairsSection
            sanctionsSection
            debtsSection
            movementsSection
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
            await loadPoolBalance()
            await loadPermissions()
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
        .sheet(isPresented: $isShowingContribute) {
            ContributeToPoolSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            ) {
                isShowingContribute = false
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $isShowingPoolCharge) {
            IssuePoolChargeSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId
            ) {
                isShowingPoolCharge = false
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

    /// V3 — hero rediseñado para resolver confusión doctrinal.
    ///
    /// El balance canónico mezcla pool-side + peer-side; mostrarlo con
    /// label "El grupo te debe" era engañoso porque parte del numero
    /// son saldos peer-to-peer. Ahora el hero muestra UN número, lo
    /// llama "Tu saldo neto en este grupo", y deja que los bloques
    /// debajo (Fondo del grupo, Entre miembros) expliquen qué hay
    /// detrás de la cifra.
    @ViewBuilder
    private var heroCard: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(heroLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(heroAmount, format: .currency(code: "MXN"))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(heroColor)
            Text("Tu saldo neto (todo lo que debes/te deben en este grupo).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 2)
        }
    }

    private var heroAmount: Decimal {
        container.moneyStore.balance ?? 0
    }

    /// V3 — etiquetas reescritas para evitar la frase "el grupo te debe"
    /// (engañosa porque parte del saldo es peer-to-peer). Ahora son
    /// caller-centric sin suponer contraparte.
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
        // Doctrine: no hardcoded colors. The amount string itself carries
        // the +/− sign; the hero stays neutral so users read it via shape.
        guard container.moneyStore.balance != nil else { return .secondary }
        return .primary
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
                .foregroundStyle(.secondary)
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

    // MARK: - Pool balance (V3 — Q1 answer, rediseñado)
    //
    // El fondo común del grupo. Always-visible (incluso $0) para que
    // el caller aprenda el concepto. Copy "El fondo común tiene" deja
    // claro que es del GRUPO, no del caller. Subtitle explica cómo se
    // forma (aportes + multas − retiros) para que la cifra no luzca
    // mágica.

    @ViewBuilder
    private var poolBalanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Image(systemName: "building.columns.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fondo común del grupo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(poolNetForDisplay, format: .currency(code: poolUnit))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(poolColorForDisplay)
                    }
                    Spacer()
                }
                if poolBalance != nil {
                    Text(poolExplainer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("El grupo")
        }
    }

    /// Si el pool aún no cargó, muestra 0 (no nil) para mantener el
    /// layout estable y el caller no vea una sección apareciendo a
    /// mitad de scroll.
    private var poolNetForDisplay: Decimal {
        poolBalance?.net ?? 0
    }

    private var poolUnit: String {
        poolBalance?.unit ?? "MXN"
    }

    private var poolColorForDisplay: Color {
        // Doctrine: no hardcoded colors. The signed amount string already
        // tells the user direction; keep the value neutral.
        guard poolBalance != nil else { return .secondary }
        return .primary
    }

    /// Pluraliza la explicación según los flows reales del grupo:
    /// "Sumas: $X de aportes y $Y de multas pagadas." etc. Hace la
    /// cifra interpretable sin abrir un detail.
    private var poolExplainer: String {
        guard let pool = poolBalance else { return "" }
        var parts: [String] = []
        if pool.contributionsIn > 0 {
            parts.append("\(pool.contributionsIn.formatted()) en aportes")
        }
        if pool.settlementsIn > 0 {
            parts.append("\(pool.settlementsIn.formatted()) en multas pagadas")
        }
        if pool.payoutsOut > 0 {
            parts.append("\(pool.payoutsOut.formatted()) retirados")
        }
        if parts.isEmpty {
            return "Aún sin movimientos. Crece con aportes y multas pagadas, baja con retiros."
        }
        return "Resultado: " + parts.joined(separator: " + ")
    }

    // MARK: - Quick actions row (V3 — UX redesign)
    //
    // Doctrine ruul_canonical_ux_doctrine: las acciones primarias del
    // tab deben estar arriba (no enterradas al fondo). Patron horizontal
    // chip row right under hero — verbos directos, alta accesibilidad
    // sin necesidad de scroll. Cada chip activo solo cuando aplica.

    @ViewBuilder
    private var quickActionsRow: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    actionChip(
                        label: "Aportar",
                        icon: "arrow.down.to.line.circle.fill"
                    ) {
                        isShowingContribute = true
                    }
                    actionChip(
                        label: "Registrar gasto",
                        icon: "plus.circle.fill"
                    ) {
                        isShowingExpenseSheet = true
                    }
                    if !container.moneyStore.settlementPlan.isEmpty {
                        actionChip(
                            label: "Saldar cuentas",
                            icon: "sparkles"
                        ) {
                            isShowingSettleUp = true
                        }
                    }
                    actionChip(
                        label: "Pagar a alguien",
                        icon: "checkmark.circle.fill"
                    ) {
                        isShowingSettlementSheet = true
                    }
                    // D.22 audit — pool_charge.record es admin-only por
                    // default. Members no ven el chip (era tap-then-403).
                    if permissionKeys?.contains("pool_charge.record") == true {
                        actionChip(
                            label: "Cobrar cuota",
                            icon: "arrow.up.to.line.circle.fill"
                        ) {
                            isShowingPoolCharge = true
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func actionChip(
        label: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Refresh

    private func refresh() async {
        await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
        await container.sanctionsStore.refresh(groupId: groupId)
        await container.movementsStore.refresh(groupId: groupId)
        await loadPoolBalance()
    }

    /// V3 — silent load; si falla la sección queda invisible.
    private func loadPoolBalance() async {
        do {
            poolBalance = try await container.moneyRepository.poolBalance(groupId: groupId)
        } catch {
            poolBalance = nil
        }
    }

    /// D.22 audit — load caller permissions; silent on error.
    private func loadPermissions() async {
        do {
            permissionKeys = try await container.groupRepository.listMemberPermissions(
                groupId: groupId,
                userId: nil
            )
        } catch {
            permissionKeys = []
        }
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

