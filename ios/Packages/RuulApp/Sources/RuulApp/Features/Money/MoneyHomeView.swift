import SwiftUI
import RuulCore

/// F.MONEY.1 + R.5V.X 2026-06-08 — Dinero Apple-native (List + Section).
///
/// Responde en menos de 2 segundos: ¿debo? ¿me deben? ¿cuánto? ¿qué hago?
///
/// Refactor visual del dashboard legacy (ScrollView+VStack con custom cards)
/// al pattern firmado V.3/V.4/V.5: `List + Section + .listStyle(.insetGrouped)`.
/// Cero `Theme.Surface.card` / `Theme.cardShape()` envueltos custom. Hero
/// se mantiene visualmente prominente como Section con
/// `.listRowBackground(.clear) + .listRowSeparator(.hidden)`.
public struct MoneyHomeView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: MoneyStore
    @State private var isShowingExpense = false
    @State private var isShowingGameResult = false
    @State private var isShowingFine = false
    @State private var selectedObligationId: UUID?

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: MoneyStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()

            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }

            case .loaded:
                content
            }
        }
        .navigationTitle("Dinero")
        .task { await store.load(context: context) }
        .refreshable { await store.load(context: context) }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar { toolbarPlus }
        .sheet(isPresented: $isShowingExpense) {
            RecordExpenseView(context: context, store: store, container: container)
        }
        .sheet(isPresented: $isShowingGameResult) {
            RecordGameResultView(context: context, store: store, container: container)
        }
        .sheet(isPresented: $isShowingFine) {
            RecordFineView(context: context, store: store, container: container)
        }
        .sheet(item: Binding(
            get: { selectedObligationId.map { ObligationSheetItem(id: $0) } },
            set: { selectedObligationId = $0?.id }
        )) { item in
            ObligationDetailView(obligationId: item.id, context: context, container: container)
        }
    }

    @ToolbarContentBuilder
    private var toolbarPlus: some ToolbarContent {
        let recordActions = store.availableActions.filter { recordActionKeys.contains($0.actionKey) }
        if !recordActions.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Registrar") {
                        ForEach(recordActions) { action in
                            Button {
                                handle(actionKey: action.actionKey)
                            } label: {
                                Label(
                                    action.label,
                                    systemImage: ActionPresentationCatalog.presentation(for: action.actionKey).symbolName
                                )
                            }
                            .disabled(!action.enabled)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Registrar movimiento")
            }
        } else if store.canRecord(in: context) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Registrar") {
                        Button { isShowingExpense = true } label: {
                            Label("Registrar gasto", systemImage: "cart.fill")
                        }
                        Button { isShowingGameResult = true } label: {
                            Label("Resultado de juego", systemImage: "dice.fill")
                        }
                        Button { isShowingFine = true } label: {
                            Label("Multa manual", systemImage: "exclamationmark.circle.fill")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Registrar movimiento")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            heroSection
            if !visiblePending.isEmpty {
                pendientesSection
            }
            accionesSection
            fondosSection
            if !moneyActivity.isEmpty {
                actividadSection
            }
            detallesSection
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Datos derivados

    private var openMoney: [Obligation] {
        store.openObligations.filter(\.isMoneyKind)
    }

    private var visiblePending: [Obligation] {
        store.openObligations
    }

    private var owedToMe: Double {
        openMoney
            .filter { $0.creditorActorId == myActorId }
            .compactMap(\.amount)
            .reduce(0, +)
    }

    private var iOwe: Double {
        openMoney
            .filter { $0.debtorActorId == myActorId }
            .compactMap(\.amount)
            .reduce(0, +)
    }

    private var distinctDebtorCount: Int {
        Set(
            openMoney
                .filter { $0.creditorActorId == myActorId }
                .map(\.debtorActorId)
        ).count
    }

    private var iOweCount: Int {
        openMoney.filter { $0.debtorActorId == myActorId }.count
    }

    private var currencyCode: String? {
        openMoney.compactMap(\.currency).first ?? store.obligations.compactMap(\.currency).first
    }

    // MARK: - Hero (Section row con typography prominente, sin custom card)

    @ViewBuilder
    private var heroSection: some View {
        Section {
            heroContent
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 8, trailing: 4))
        }
    }

    @ViewBuilder
    private var heroContent: some View {
        if owedToMe == 0 && iOwe == 0 {
            heroAllClear
        } else if iOwe == 0 {
            heroOwedToMe
        } else if owedToMe == 0 {
            heroIOwe
        } else {
            heroMixed
        }
    }

    private var heroAllClear: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(Theme.Tint.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Todo está al día")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.Text.primary)
                    Text("No debes dinero. Nadie te debe dinero.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                }
                Spacer(minLength: 0)
            }
            if store.canRecord(in: context) {
                Button {
                    isShowingExpense = true
                } label: {
                    Label("Registrar gasto", systemImage: "cart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var heroOwedToMe: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Te deben", systemImage: "arrow.up.right.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Tint.success)
            Text(owedToMe.currencyLabel(currencyCode))
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Tint.success)
            Text(distinctDebtorCount == 1 ? "1 persona" : "\(distinctDebtorCount) personas")
                .font(.subheadline)
                .foregroundStyle(Theme.Text.secondary)
        }
    }

    private var heroIOwe: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Debes", systemImage: "arrow.down.right.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Tint.critical)
                Text(iOwe.currencyLabel(currencyCode))
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.Tint.critical)
                Text(iOweCount == 1 ? "1 pago pendiente" : "\(iOweCount) pagos pendientes")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Text.secondary)
            }
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                Label("Ver cómo liquidar", systemImage: "creditcard.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.Tint.critical)
        }
    }

    private var heroMixed: some View {
        let net = owedToMe - iOwe
        let netPositive = net >= 0
        let netLabel = (netPositive ? "+" : "−") + abs(net).currencyLabel(currencyCode)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Te deben", systemImage: "arrow.up.right.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Tint.success)
                        .labelStyle(.titleAndIcon)
                    Text(owedToMe.currencyLabel(currencyCode))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.Tint.success)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Label("Debes", systemImage: "arrow.down.right.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Tint.critical)
                        .labelStyle(.titleAndIcon)
                    Text(iOwe.currencyLabel(currencyCode))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.Tint.critical)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Resultado neto")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Text.secondary)
                Text(netLabel)
                    .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(netPositive ? Theme.Tint.success : Theme.Tint.critical)
            }
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                Label("Ver cómo liquidar", systemImage: "creditcard.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Pendientes

    @ViewBuilder
    private var pendientesSection: some View {
        Section {
            ForEach(visiblePending) { obligation in
                Button {
                    selectedObligationId = obligation.id
                } label: {
                    pendienteRow(obligation)
                }
            }
        } header: {
            Text("Pendientes (\(visiblePending.count))")
        }
    }

    @ViewBuilder
    private func pendienteRow(_ obligation: Obligation) -> some View {
        // P0 fix 2026-06-08: Button + LabeledContent dentro de List causaba
        // crash al tap. Simplificado a HStack plano + .contentShape Rectangle
        // para hit-test estable.
        HStack(spacing: 12) {
            Image(systemName: pendienteIcon(obligation))
                .foregroundStyle(amountTint(obligation))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(pendienteTitle(obligation))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if let subtitle = pendienteSubtitle(obligation) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let amount = obligation.amount {
                Text(amount.currencyLabel(obligation.currency))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(amountTint(obligation))
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Text.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func pendienteIcon(_ obligation: Obligation) -> String {
        if obligation.creditorActorId == myActorId { return "arrow.up.right.circle.fill" }
        if obligation.debtorActorId == myActorId   { return "arrow.down.right.circle.fill" }
        return "arrow.left.and.right.circle.fill"
    }

    private func pendienteTitle(_ obligation: Obligation) -> String {
        if obligation.creditorActorId == myActorId {
            return "\(store.displayName(for: obligation.debtorActorId)) te debe"
        }
        if obligation.debtorActorId == myActorId {
            return "Tú debes a \(store.displayName(for: obligation.creditorActorId))"
        }
        let debtor = store.displayName(for: obligation.debtorActorId)
        let creditor = store.displayName(for: obligation.creditorActorId)
        return "\(debtor) → \(creditor)"
    }

    private func pendienteSubtitle(_ obligation: Obligation) -> String? {
        if let title = obligation.title, !title.isEmpty { return title }
        if let description = obligation.description, !description.isEmpty { return description }
        return obligation.typeLabel
    }

    private func amountTint(_ obligation: Obligation) -> Color {
        if obligation.creditorActorId == myActorId { return Theme.Tint.success }
        if obligation.debtorActorId == myActorId { return Theme.Tint.critical }
        return Theme.Text.primary
    }

    // MARK: - Acciones

    @ViewBuilder
    private var accionesSection: some View {
        let backendActions = store.availableActions.filter { moneyActionKeys.contains($0.actionKey) }
        Section {
            ForEach(backendActions) { action in
                Button {
                    handle(actionKey: action.actionKey)
                } label: {
                    Label(
                        action.label,
                        systemImage: ActionPresentationCatalog.presentation(for: action.actionKey).symbolName
                    )
                }
                .disabled(!action.enabled)
                .accessibilityHint(action.reason ?? "")
            }
            NavigationLink {
                ActivityFeedView(context: context, container: container)
            } label: {
                Label("Ver historial completo", systemImage: "clock.arrow.circlepath")
            }
        } header: {
            Text("Qué puedes hacer")
        }
    }

    private func handle(actionKey: String) {
        // F.2X — el mapeo key→destino vive en ActionRouter; aquí sólo se
        // decide qué sheet local abrir.
        switch ActionRouter.quickActionDestination(for: actionKey) {
        case .recordExpense:    isShowingExpense = true
        case .recordFine:       isShowingFine = true
        case .recordGameResult: isShowingGameResult = true
        default: break
        }
    }

    // MARK: - Fondos (R.8.E)

    @ViewBuilder
    private var fondosSection: some View {
        Section {
            NavigationLink {
                PoolsListView(context: context, container: container)
            } label: {
                Label("Fondos", systemImage: "banknote.fill")
            }
        } header: {
            Text("Fondos")
        } footer: {
            Text("Botes y fondos con meta del contexto.")
        }
    }

    // MARK: - Actividad

    private var moneyActivity: [SummaryActivity] {
        store.recentActivity
            .filter { moneyDomains.contains(String($0.eventType.split(separator: ".").first ?? "")) }
            .prefix(10)
            .map { $0 }
    }

    @ViewBuilder
    private var actividadSection: some View {
        Section {
            ForEach(Array(moneyActivity.enumerated()), id: \.offset) { _, item in
                activityRow(item)
            }
            NavigationLink {
                ActivityFeedView(context: context, container: container)
            } label: {
                Label("Ver toda la actividad", systemImage: "list.bullet")
            }
        } header: {
            Text("Actividad reciente")
        }
    }

    @ViewBuilder
    private func activityRow(_ item: SummaryActivity) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(activityTitle(item))
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                if let date = item.occurredAt {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
        } icon: {
            Image(systemName: activityIcon(item.eventType))
                .foregroundStyle(activityTint(item.eventType))
        }
    }

    private func activityIcon(_ eventType: String) -> String {
        switch eventType {
        case "expense.recorded":           return "cart.fill"
        case "fine.created":               return "exclamationmark.circle.fill"
        case "game_result.recorded":       return "dice.fill"
        case "obligation.created":         return "doc.text.fill"
        case "obligation.completed",
             "obligation.fulfilled",
             "obligation.settled",
             "obligation.paid":            return "checkmark.circle.fill"
        case "obligation.cancelled":       return "xmark.circle.fill"
        case "obligation.disputed":        return "exclamationmark.bubble.fill"
        case "obligation.forgiven":        return "heart.fill"
        case "settlement.generated":      return "creditcard.fill"
        case "settlement.paid":            return "checkmark.seal.fill"
        case "split.generated":            return "divide.circle.fill"
        default:                           return "bolt.circle.fill"
        }
    }

    private func activityTint(_ eventType: String) -> Color {
        switch eventType {
        case "expense.recorded", "settlement.generated", "settlement.paid",
             "obligation.completed", "obligation.fulfilled", "obligation.settled",
             "obligation.paid":
            return Theme.Tint.success
        case "fine.created":
            return Theme.Tint.warning
        case "obligation.cancelled", "obligation.disputed":
            return Theme.Tint.critical
        default:
            return Theme.Tint.primary
        }
    }

    private func activityTitle(_ item: SummaryActivity) -> String {
        let actor = store.displayName(for: item.actorId)
        switch item.eventType {
        case "expense.recorded":     return "\(actor) registró un gasto"
        case "fine.created":         return "\(actor) registró una multa"
        case "game_result.recorded": return "\(actor) registró resultado de juego"
        case "obligation.created":   return "Nueva obligación"
        case "obligation.completed", "obligation.fulfilled": return "Obligación cumplida"
        case "obligation.settled", "obligation.paid":        return "\(actor) pagó"
        case "obligation.cancelled": return "Obligación cancelada"
        case "obligation.disputed":  return "Obligación disputada"
        case "obligation.forgiven":  return "Obligación perdonada"
        case "settlement.generated": return "Liquidación generada"
        case "settlement.paid":      return "\(actor) liquidó un pago"
        case "split.generated":      return "Reparto generado"
        default:
            let cleaned = item.eventType
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
    }

    // MARK: - Detalles

    @ViewBuilder
    private var detallesSection: some View {
        Section {
            LabeledContent {
                Text(balanceBruto.currencyLabel(currencyCode))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: balanceBruto))
            } label: {
                Label("Balance bruto", systemImage: "scalemass.fill")
            }
            LabeledContent {
                Text(iOwe.currencyLabel(currencyCode))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(iOwe > 0 ? Theme.Tint.critical : Theme.Text.primary)
                    .contentTransition(.numericText(value: iOwe))
            } label: {
                Label("Deuda total", systemImage: "arrow.down.right.circle.fill")
            }
            LabeledContent {
                Text(owedToMe.currencyLabel(currencyCode))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(owedToMe > 0 ? Theme.Tint.success : Theme.Text.primary)
                    .contentTransition(.numericText(value: owedToMe))
            } label: {
                Label("Crédito total", systemImage: "arrow.up.right.circle.fill")
            }
            LabeledContent {
                Text("\(openMoney.count)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(openMoney.count)))
            } label: {
                Label("Obligaciones abiertas", systemImage: "doc.text.below.ecg.fill")
            }
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                Label("Liquidación completa", systemImage: "creditcard.fill")
            }
        } header: {
            Text("Detalles")
        }
    }

    private var balanceBruto: Double {
        let total = store.members
            .map { abs(store.balance(for: $0.actorId)) }
            .reduce(0, +)
        return total / 2
    }

    // MARK: - Helpers

    private let recordActionKeys: Set<String> = [
        "record_expense", "record_fine", "record_game_result"
    ]

    private var moneyActionKeys: Set<String> { recordActionKeys }

    private let moneyDomains: Set<String> = [
        "expense", "fine", "obligation", "settlement", "split", "game_result"
    ]
}

private struct ObligationSheetItem: Identifiable {
    let id: UUID
}

#Preview("Dinero") {
    NavigationStack {
        MoneyHomeView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
