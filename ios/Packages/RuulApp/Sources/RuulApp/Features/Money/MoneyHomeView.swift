import SwiftUI
import RuulCore

/// F.MONEY.1 — Dinero rediseñado Apple-first / human-first.
/// Responde en menos de 2 segundos: ¿debo? ¿me deben? ¿cuánto? ¿qué hago?
public struct MoneyHomeView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: MoneyStore
    @State private var isShowingExpense = false
    @State private var isShowingGameResult = false
    @State private var isShowingFine = false
    @State private var selectedObligationId: UUID?
    @State private var showDetalles = false

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
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
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
                    ForEach(recordActions) { action in
                        Button {
                            handle(actionKey: action.actionKey)
                        } label: {
                            Label(action.label, systemImage: ActionPresentationCatalog.presentation(for: action.actionKey).symbolName)
                        }
                        .disabled(!action.enabled)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        } else if store.canRecord(in: context) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { isShowingExpense = true } label: {
                        Label("Registrar gasto", systemImage: "cart")
                    }
                    Button { isShowingGameResult = true } label: {
                        Label("Resultado de juego", systemImage: "dice")
                    }
                    Button { isShowingFine = true } label: {
                        Label("Multa manual", systemImage: "exclamationmark.circle")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                heroSection
                if !visiblePending.isEmpty {
                    pendientesSection
                }
                accionesSection
                if !moneyActivity.isEmpty {
                    actividadSection
                }
                detallesSection
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.lg)
        }
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

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("🎉 Todo está al día")
                    .font(.title2.weight(.bold))
                Text("No debes dinero. Nadie te debe dinero.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if store.canRecord(in: context) {
                Button {
                    isShowingExpense = true
                } label: {
                    Text("Registrar gasto")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    private var heroOwedToMe: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Te deben")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(owedToMe.currencyLabel(currencyCode))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text(distinctDebtorCount == 1 ? "1 persona" : "\(distinctDebtorCount) personas")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    private var heroIOwe: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Debes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(iOwe.currencyLabel(currencyCode))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                Text(iOweCount == 1 ? "1 pago pendiente" : "\(iOweCount) pagos pendientes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                Text("Ver cómo liquidar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    private var heroMixed: some View {
        let net = owedToMe - iOwe
        let netPositive = net >= 0
        let netLabel = (netPositive ? "+" : "−") + abs(net).currencyLabel(currencyCode)

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Te deben")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(owedToMe.currencyLabel(currencyCode))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Debes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(iOwe.currencyLabel(currencyCode))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Resultado neto")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(netLabel)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(netPositive ? .green : .red)
            }
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                Text("Ver cómo liquidar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    // MARK: - Pendientes

    private var pendientesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("Pendientes")
            VStack(spacing: 0) {
                ForEach(Array(visiblePending.enumerated()), id: \.element.id) { idx, obligation in
                    Button {
                        selectedObligationId = obligation.id
                    } label: {
                        pendienteRow(obligation)
                    }
                    .buttonStyle(.plain)
                    if idx < visiblePending.count - 1 {
                        Divider().padding(.leading, Theme.Spacing.lg)
                    }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func pendienteRow(_ obligation: Obligation) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(pendienteTitle(obligation))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = pendienteSubtitle(obligation) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            if let amount = obligation.amount {
                Text(amount.currencyLabel(obligation.currency))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(amountTint(obligation))
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
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
        if obligation.creditorActorId == myActorId { return .green }
        if obligation.debtorActorId == myActorId { return .red }
        return .primary
    }

    // MARK: - Acciones

    private var accionesSection: some View {
        let backendActions = store.availableActions.filter { moneyActionKeys.contains($0.actionKey) }
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("Qué puedes hacer")
            VStack(spacing: 0) {
                ForEach(backendActions) { action in
                    Button {
                        handle(actionKey: action.actionKey)
                    } label: {
                        actionRow(label: action.label, enabled: action.enabled, hint: action.reason)
                    }
                    .buttonStyle(.plain)
                    .disabled(!action.enabled)
                    Divider().padding(.leading, Theme.Spacing.lg)
                }
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    actionRow(label: "Ver historial", enabled: true, hint: nil)
                }
                .buttonStyle(.plain)
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func actionRow(label: String, enabled: Bool, hint: String?) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label)
                .font(.body)
                .foregroundStyle(enabled ? .primary : .tertiary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
        .accessibilityHint(hint ?? "")
    }

    private func handle(actionKey: String) {
        switch actionKey {
        case "record_expense": isShowingExpense = true
        case "record_fine":    isShowingFine = true
        case "record_game_result": isShowingGameResult = true
        default: break
        }
    }

    // MARK: - Actividad

    private var moneyActivity: [SummaryActivity] {
        store.recentActivity
            .filter { moneyDomains.contains(String($0.eventType.split(separator: ".").first ?? "")) }
            .prefix(10)
            .map { $0 }
    }

    private var actividadSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("Actividad reciente")
            VStack(spacing: 0) {
                ForEach(Array(moneyActivity.enumerated()), id: \.offset) { idx, item in
                    activityRow(item)
                    if idx < moneyActivity.count - 1 {
                        Divider().padding(.leading, Theme.Spacing.lg)
                    }
                }
                Divider().padding(.leading, Theme.Spacing.lg)
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    actionRow(label: "Ver actividad", enabled: true, hint: nil)
                }
                .buttonStyle(.plain)
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func activityRow(_ item: SummaryActivity) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(activityTitle(item))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let date = item.occurredAt {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
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

    // MARK: - Detalles (colapsable)

    private var detallesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            DisclosureGroup(isExpanded: $showDetalles) {
                VStack(spacing: 0) {
                    detalleRow("Balance bruto", value: balanceBruto.currencyLabel(currencyCode))
                    Divider().padding(.leading, Theme.Spacing.lg)
                    detalleRow("Deuda total", value: iOwe.currencyLabel(currencyCode))
                    Divider().padding(.leading, Theme.Spacing.lg)
                    detalleRow("Crédito total", value: owedToMe.currencyLabel(currencyCode))
                    Divider().padding(.leading, Theme.Spacing.lg)
                    detalleRow("Obligaciones abiertas", value: "\(openMoney.count)")
                    Divider().padding(.leading, Theme.Spacing.lg)
                    NavigationLink {
                        SettlementView(context: context, container: container)
                    } label: {
                        HStack {
                            Text("Liquidación")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
                .padding(.top, Theme.Spacing.sm)
            } label: {
                Text("Detalles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .tint(.secondary)
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }

    private var balanceBruto: Double {
        let total = store.members
            .map { abs(store.balance(for: $0.actorId)) }
            .reduce(0, +)
        return total / 2
    }

    @ViewBuilder
    private func detalleRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.xs)
    }

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
