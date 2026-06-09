import SwiftUI
import RuulCore

/// F.8 — lista de reglas del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native + Liquid Glass (mismo patrón
/// que MyResourcesView / EventsListView / MembersListView v3):
/// 1. Hero Liquid Glass: count de activas + breakdown chips por trigger
/// 2. `.searchable` para filtrar por título / descripción
/// 3. Sections por trigger semántico (Eventos / Reservaciones / Dinero / Otros)
///    con tints. Final: section "Pausadas" para rules con status != active.
/// 4. Estados Ruul* (Loading/Error/Empty)
public struct RulesListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: RulesStore
    @State private var isShowingCreate = false
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
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear regla", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateRuleWizard(context: context, store: store, rpc: container.rpc)
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private var loadedContent: some View {
        if store.rules.isEmpty {
            RuulEmptyState(
                title: "Sin reglas",
                systemImage: "ruler",
                message: "Las reglas convierten acuerdos en consecuencias automáticas: llegar tarde → multa, cancelar el mismo día → multa."
            )
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

    // MARK: - Hero (Liquid Glass)

    @ViewBuilder
    private func heroSection(_ rules: [Rule]) -> some View {
        let active = rules.filter(\.isActive)
        let byGroup = Dictionary(grouping: active, by: { RuleGroup.from($0) })
        let breakdown = RuleGroup.displayOrder.compactMap { g -> (RuleGroup, Int)? in
            guard let count = byGroup[g]?.count, count > 0 else { return nil }
            return (g, count)
        }
        Section {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(active.count)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Tint.primary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(active.count == 1 ? "regla activa" : "reglas activas")
                                .font(.callout)
                                .foregroundStyle(Theme.Text.secondary)
                            if rules.count > active.count {
                                Text("\(rules.count - active.count) pausada\(rules.count - active.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if !breakdown.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.xs) {
                                ForEach(breakdown, id: \.0) { group, count in
                                    groupChip(group, count: count)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.lg, bottom: Theme.Spacing.md, trailing: Theme.Spacing.lg))
        }
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
        case .decisions:    return "Decisiones"
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
