import SwiftUI
import RuulCore

/// F.8 — lista de reglas del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native (mismo patrón
/// que MyResourcesView / EventsListView / MembersListView v3):
/// 1. Hero plano (lenguaje del hero de Dinero): count de activas + breakdown
///    chips por trigger
/// 2. `.searchable` para filtrar por título / descripción
/// 3. Sections por trigger semántico (Eventos / Reservaciones / Dinero / Otros)
///    con tints. Final: section "Pausadas" para rules con status != active.
/// 4. Estados Ruul* (Loading/Error/Empty)
public struct RulesListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: RulesStore
    @State private var isShowingCreate = false
    @State private var isShowingPresetLibrary = false
    @State private var query: String = ""

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: RulesStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando reglas…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Reglas")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .toolbar {
            if store.canManage(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isShowingPresetLibrary = true
                        } label: {
                            Label("Usar preset", systemImage: "square.grid.2x2.fill")
                        }
                        Button {
                            isShowingCreate = true
                        } label: {
                            Label("Crear regla", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Crear regla")
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateRuleWizard(context: context, store: store, rpc: container.rpc)
        }
        .sheet(isPresented: $isShowingPresetLibrary) {
            RulePresetLibrarySheet(context: context, store: store)
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private var loadedContent: some View {
        if store.rules.isEmpty {
            List {
                Section {
                    RuulEmptyState(
                        title: "Sin reglas",
                        systemImage: "ruler",
                        message: "Elige un preset para arrancar rápido o crea una regla personalizada."
                    )
                    .listRowBackground(Color.clear)
                    if store.canManage(in: context) {
                        Button {
                            isShowingPresetLibrary = true
                        } label: {
                            Label("Elegir preset", systemImage: "square.grid.2x2.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else {
            let filtered = filter(store.rules)
            let active = filtered.filter(\.isActive)
            let paused = filtered.filter { !$0.isActive }
            let groupedActive = groupByTrigger(active)
            List {
                heroSection(store.rules)
                ForEach(RuleGroup.displayOrder, id: \.self) { group in
                    if let items = groupedActive[group], !items.isEmpty {
                        Section {
                            ForEach(items) { rule in
                                ruleRow(rule, group: group, isPaused: false)
                            }
                        } header: {
                            HStack {
                                Label(group.displayName, systemImage: group.symbolName)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Text("\(items.count)")
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
                if !paused.isEmpty {
                    Section {
                        ForEach(paused) { rule in
                            ruleRow(rule, group: RuleGroup.from(rule), isPaused: true)
                        }
                    } header: {
                        HStack {
                            Label("Pausadas", systemImage: "pause.circle.fill")
                                .foregroundStyle(Theme.Text.tertiary)
                            Spacer()
                            Text("\(paused.count)")
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
                if groupedActive.isEmpty && paused.isEmpty {
                    Section {
                        Text("Sin coincidencias con \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
                Section {} footer: {
                    Text("Las reglas se evalúan automáticamente cada vez que ocurre el evento. Las multas aparecen como obligaciones; las alertas en \"Atención\".")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar regla")
            .searchToolbarBehavior(.minimize)
        }
    }

    // MARK: - Hero (R.17 — mismo lenguaje que el hero de Dinero: typography
    // prominente plana, etiqueta semántica y botón de acción. Sin glass flotante.)

    @ViewBuilder
    private func heroSection(_ rules: [Rule]) -> some View {
        let active = rules.filter(\.isActive)
        let byGroup = Dictionary(grouping: active, by: { RuleGroup.from($0) })
        let breakdown = RuleGroup.displayOrder.compactMap { g -> (RuleGroup, Int)? in
            guard let count = byGroup[g]?.count, count > 0 else { return nil }
            return (g, count)
        }
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Reglas", systemImage: "scroll")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Tint.primary)
                    Text("\(active.count)")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.Text.primary)
                    Text(heroSubtitle(activeCount: active.count, pausedCount: rules.count - active.count))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                }
                if breakdown.count > 1 {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(breakdown, id: \.0) { group, count in
                            groupChip(group, count: count)
                        }
                    }
                }
                if store.canManage(in: context) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear regla", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
            .ruulHeroRow()
        }
    }

    private func heroSubtitle(activeCount: Int, pausedCount: Int) -> String {
        var parts: [String] = [activeCount == 1 ? "regla activa" : "reglas activas"]
        if pausedCount > 0 {
            parts.append("\(pausedCount) pausada\(pausedCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func groupChip(_ group: RuleGroup, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: group.symbolName)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(group.tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(group.tint.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Rule row

    @ViewBuilder
    private func ruleRow(_ rule: Rule, group: RuleGroup, isPaused: Bool) -> some View {
        NavigationLink {
            RuleDetailView(
                rule: rule,
                context: context,
                container: container,
                canManage: store.canManage(in: context),
                onChanged: { Task { await store.load(context: context) } }
            )
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.title)
                        .foregroundStyle(isPaused ? Theme.Text.secondary : Theme.Text.primary)
                        .lineLimit(1)
                    Text(rule.conditionDescription + " → " + rule.consequenceDescription)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: group.symbolName)
                    .foregroundStyle(isPaused ? Theme.Text.tertiary : group.tint)
            }
        }
    }

    // MARK: - Filter + group

    private func filter(_ rules: [Rule]) -> [Rule] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rules }
        return rules.filter { r in
            r.title.lowercased().contains(q)
                || (r.body?.lowercased().contains(q) ?? false)
                || r.conditionDescription.lowercased().contains(q)
                || r.consequenceDescription.lowercased().contains(q)
        }
    }

    private func groupByTrigger(_ rules: [Rule]) -> [RuleGroup: [Rule]] {
        Dictionary(grouping: rules, by: { RuleGroup.from($0) })
            .mapValues { $0.sorted { $0.title < $1.title } }
    }
}

// MARK: - Preset Library

/// 2026-06-21 — `public` para que HomeView pueda abrirla desde el QuickStart
/// "Elegir reglas" sin pasar por Ajustes. Friend-group onboarding P0 #7.
public struct RulePresetLibrarySheet: View {
    let context: AppContext
    let store: RulesStore

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()

    public init(context: AppContext, store: RulesStore) {
        self.context = context
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(GroupRulePreset.allCases) { preset in
                        Button {
                            Task { await apply(preset) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.symbolName)
                                    .font(.title3)
                                    .foregroundStyle(preset.tint)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(Theme.Text.primary)
                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(runner.isRunning)
                    }
                } header: {
                    Text("Cómo funciona nuestro grupo")
                } footer: {
                    Text("Los presets crean reglas editables. Ruul omite reglas con el mismo título si ya existen.")
                }
            }
            .navigationTitle("Biblioteca de reglas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func apply(_ preset: GroupRulePreset) async {
        let existingTitles = Set(store.rules.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let inputs = preset.inputs(contextId: context.id).filter { input in
            !existingTitles.contains(input.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let success = await runner.run {
            for input in inputs {
                _ = try await store.createRule(input, context: context)
            }
        }
        if success { dismiss() }
    }
}

private enum GroupRulePreset: String, CaseIterable, Identifiable {
    case relaxedDinner
    case organizedDinner
    case competitiveGroup
    case travelers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relaxedDinner:    return "Cena relajada"
        case .organizedDinner:  return "Cena organizada"
        case .competitiveGroup: return "Grupo competitivo"
        case .travelers:        return "Viajeros"
        }
    }

    var subtitle: String {
        switch self {
        case .relaxedDinner:
            return "Sin multas; acuerdos visibles para convivir sin presión."
        case .organizedDinner:
            return "Tolerancia de llegada, cancelación tardía y norma de no-show."
        case .competitiveGroup:
            return "Multas base y norma de puntos para rankings y juegos."
        case .travelers:
            return "Fondo común, reservaciones y cancelaciones para viajes."
        }
    }

    var symbolName: String {
        switch self {
        case .relaxedDinner:    return "fork.knife"
        case .organizedDinner:  return "calendar.badge.checkmark"
        case .competitiveGroup: return "trophy.fill"
        case .travelers:        return "airplane"
        }
    }

    var tint: Color {
        switch self {
        case .relaxedDinner:    return Theme.Tint.success
        case .organizedDinner:  return Theme.Tint.warning
        case .competitiveGroup: return .purple
        case .travelers:        return Theme.Tint.info
        }
    }

    func inputs(contextId: UUID) -> [CreateRuleInput] {
        switch self {
        case .relaxedDinner:
            return [
                norm(
                    contextId: contextId,
                    title: "Sin multas por defecto",
                    body: "El grupo no cobra multas automáticas. Los gastos se registran y se liquidan con buena fe."
                )
            ]

        case .organizedDinner:
            return [
                CreateRuleInput(
                    contextId: contextId,
                    title: "Multa por llegar tarde (>15 min)",
                    triggerEventType: RuleTrigger.checkedIn.rawValue,
                    conditionTree: RuleConditionBuilder.lateMoreThan(minutes: 15),
                    consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN"),
                    ruleType: "automation"
                ),
                CreateRuleInput(
                    contextId: contextId,
                    title: "Multa por cancelar el mismo día",
                    triggerEventType: RuleTrigger.participationCancelled.rawValue,
                    conditionTree: RuleConditionBuilder.sameDayCancellation(),
                    consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN"),
                    ruleType: "automation"
                ),
                norm(
                    contextId: contextId,
                    title: "No-show cuenta para asistencia",
                    body: "Si alguien confirma y no llega, el grupo puede marcarlo como falta al cerrar el evento."
                )
            ]

        case .competitiveGroup:
            return [
                CreateRuleInput(
                    contextId: contextId,
                    title: "Multa competitiva por llegar tarde",
                    triggerEventType: RuleTrigger.checkedIn.rawValue,
                    conditionTree: RuleConditionBuilder.lateMoreThan(minutes: 10),
                    consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN"),
                    ruleType: "automation"
                ),
                CreateRuleInput(
                    contextId: contextId,
                    title: "Multa competitiva por cancelar tarde",
                    triggerEventType: RuleTrigger.participationCancelled.rawValue,
                    conditionTree: RuleConditionBuilder.sameDayCancellation(),
                    consequences: RuleConsequenceBuilder.fine(amount: 150, currency: "MXN"),
                    ruleType: "automation"
                ),
                norm(
                    contextId: contextId,
                    title: "Puntos del grupo",
                    body: "El grupo puede llevar puntos por asistencia, juegos ganados, organización y pagos a tiempo."
                )
            ]

        case .travelers:
            return [
                CreateRuleInput(
                    contextId: contextId,
                    title: "Multa por cancelar reservación tarde",
                    triggerEventType: RuleTrigger.reservationCancelled.rawValue,
                    conditionTree: RuleConditionBuilderR2S5.cancelledLessHoursBefore(48),
                    consequences: RuleConsequenceBuilder.fine(amount: 500, currency: "MXN"),
                    ruleType: "automation",
                    targetScope: RuleTargetScope.reservation.rawValue
                ),
                norm(
                    contextId: contextId,
                    title: "Fondo común del viaje",
                    body: "El grupo usa un bote para reservas, anticipos y gastos comunes del viaje."
                ),
                norm(
                    contextId: contextId,
                    title: "Gastos del viaje",
                    body: "Los gastos compartidos se registran en Ruul y se liquidan antes de cerrar el viaje."
                )
            ]
        }
    }

    private func norm(contextId: UUID, title: String, body: String) -> CreateRuleInput {
        CreateRuleInput(
            contextId: contextId,
            title: title,
            body: body,
            ruleType: "norm"
        )
    }
}

// MARK: - RuleGroup (trigger grouping helper)

private enum RuleGroup: String, CaseIterable, Hashable {
    case events, reservations, money, decisions, other

    static let displayOrder: [RuleGroup] = [.events, .reservations, .money, .decisions, .other]

    static func from(_ rule: Rule) -> RuleGroup {
        guard let trigger = rule.triggerEventType else { return .other }
        if trigger.hasPrefix("event.")        { return .events }
        if trigger.hasPrefix("reservation.")  { return .reservations }
        if trigger.hasPrefix("expense.")
            || trigger.hasPrefix("money.")
            || trigger.hasPrefix("payment.")
            || trigger.hasPrefix("settlement.") { return .money }
        if trigger.hasPrefix("decision.")     { return .decisions }
        return .other
    }

    var displayName: String {
        switch self {
        case .events:       return "Eventos"
        case .reservations: return "Reservaciones"
        case .money:        return "Dinero"
        case .decisions:    return "Votaciones"
        case .other:        return "Otras"
        }
    }

    var symbolName: String {
        switch self {
        case .events:       return "calendar"
        case .reservations: return "calendar.badge.clock"
        case .money:        return "dollarsign.circle.fill"
        case .decisions:    return "checkmark.bubble.fill"
        case .other:        return "ruler.fill"
        }
    }

    var tint: Color {
        switch self {
        case .events:       return Theme.Tint.warning   // orange (calendar)
        case .reservations: return Theme.Tint.warning
        case .money:        return Theme.Tint.success   // green
        case .decisions:    return .purple
        case .other:        return Theme.Tint.primary
        }
    }
}

#Preview("Reglas") {
    NavigationStack {
        RulesListView(
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
