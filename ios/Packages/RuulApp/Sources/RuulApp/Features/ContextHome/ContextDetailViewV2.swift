import SwiftUI
import RuulCore

/// R.5A.F.3 + R.5V.4 — Context Detail backed by `context_detail_descriptor`.
///
/// **R.5V.4 (2026-06-07):** refactor visual a `List + Section` Apple-native.
/// La doctrina canónica firmada por founder en DocumentDetailView (V.0a §V.4)
/// se aplica aquí: **la Section ES la card**. Cero `Theme.Surface.card` /
/// `Theme.cardShape()` envueltos en VStack. Dividers/backgrounds/dynamic type
/// los maneja iOS.
///
/// Estructura visual:
///
/// ```
/// safeAreaInset(top):
///   BreadcrumbView (si tiene ancestros)
///   Picker(.segmented) 5 tabs
///
/// List(.insetGrouped) {
///   tabContent → Sections
/// }
/// ```
///
/// Toda la lógica (descriptor store, conflicts dialog modifier, attention
/// dispatcher, router, quick actions toolbar, classic sheet fallback) queda
/// intacta — sólo cambia el rendering.
public struct ContextDetailViewV2: View {
    let contextId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ContextDescriptorStore
    @State private var hierarchyStore: ContextHierarchyStore
    @State private var selectedTab: Tab = .overview
    @State private var quickActionsRouter = NoopActionRouter()
    @State private var pushedActionDestination: QuickActionPush?
    @State private var isShowingCreateChild = false
    @State private var presentedAttention: AttentionDestination?
    @State private var isShowingAllAttention = false
    @State private var conflictsList: ContextConflictList = .empty
    @State private var didLoadConflictsForContext: UUID?
    @State private var pendingContextConflict: ContextConflictItem?
    @State private var isShowingContextConflictDialog = false
    @State private var contextConflictAlert: ContextConflictsAlert?
    @State private var isShowingContextConflictAlert = false
    @State private var isResolvingContextConflict = false
    /// P0 fix 2026-06-08 — sheet de ContextSettings desde el toolbar ellipsis.
    @State private var isShowingSettings = false

    private enum QuickActionPush: Hashable, Identifiable {
        case resources, events, decisions, money, members, rules
        var id: String { String(describing: self) }
    }

    public init(contextId: UUID, context: AppContext, container: DependencyContainer) {
        self.contextId = contextId
        self.context = context
        self.container = container
        _store = State(initialValue: ContextDescriptorStore(rpc: container.rpc))
        _hierarchyStore = State(initialValue: ContextHierarchyStore(rpc: container.rpc))
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case overview, people, resources, money, more
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview:  return "Resumen"
            case .people:    return "Personas"
            case .resources: return "Recursos"
            case .money:     return "Dinero"
            case .more:      return "Más"
            }
        }
        var sectionKeys: Set<String> {
            switch self {
            case .overview:  return ["overview"]
            case .people:    return ["people"]
            case .resources: return ["resources"]
            case .money:     return ["money", "obligations"]
            case .more:      return ["calendar", "governance", "documents", "activity", "settings"]
            }
        }
    }

    public var body: some View {
        Group {
            if context.isPersonal {
                // P0 fix 2026-06-08: backend `context_detail_descriptor` raisea
                // "context not found" para actores tipo person — el descriptor
                // sólo aplica a contextos colectivos. Renderizamos un home
                // personal dedicado con drill-downs a las vistas existentes.
                personalSpaceContent
            } else {
                switch store.phase {
                case .idle, .loading:
                    LoadingStateView()
                case .failed(let message):
                    ErrorStateView(message: message) {
                        Task { await store.load(contextId: contextId) }
                    }
                case .loaded:
                    if let d = store.descriptor {
                        descriptorContent(d)
                    }
                }
            }
        }
        .navigationTitle(context.isPersonal ? "Mi espacio" : (store.descriptor?.contextDisplayName ?? "Contexto"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onChange(of: quickActionsRouter.lastOpened) { _, destination in
            guard let destination else { return }
            handleQuickAction(destination)
            quickActionsRouter.lastOpened = nil
        }
        .navigationDestination(item: $pushedActionDestination) { destination in
            switch destination {
            case .resources: ResourcesListView(context: context, container: container)
            case .events:    EventsListView(context: context, container: container)
            case .decisions: DecisionsListView(context: context, container: container)
            case .money:     MoneyHomeView(context: context, container: container)
            case .members:   MembersListView(context: context, container: container)
            case .rules:     RulesListView(context: context, container: container)
            }
        }
        .sheet(isPresented: $isShowingCreateChild) {
            CreateChildContextSheet(parent: context, container: container) { _ in
                isShowingCreateChild = false
                Task { await store.load(contextId: contextId) }
            }
        }
        .task {
            await container.attentionInboxStore.load()
            // Personal context: backend descriptor no aplica — skip.
            guard !context.isPersonal else { return }
            await store.load(contextId: contextId)
            await hierarchyStore.load(contextId: contextId)
            await loadContextConflictsIfNeeded()
        }
        .refreshable {
            await container.attentionInboxStore.load()
            guard !context.isPersonal else { return }
            await store.load(contextId: contextId)
            await hierarchyStore.load(contextId: contextId)
            await reloadContextConflicts()
        }
        .sheet(item: $presentedAttention) { destination in
            AttentionDestinationSheet(destination: destination, container: container)
        }
        .sheet(isPresented: $isShowingAllAttention) {
            NavigationStack {
                AllContextAttentionViewV2(items: contextAttentionItems) { item in
                    isShowingAllAttention = false
                    presentedAttention = AttentionDispatcher.destination(for: item)
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            ContextSettingsView(context: context, container: container)
        }
        .modifier(ContextConflictsModifier(
            pendingConflict: $pendingContextConflict,
            isShowingDialog: $isShowingContextConflictDialog,
            alert: $contextConflictAlert,
            isShowingAlert: $isShowingContextConflictAlert,
            dialogMessage: contextConflictDialogMessage(_:),
            onKind: { item, kind in resolveContextConflict(item, kind: kind) }
        ))
    }

    // MARK: - Personal space content (P0 fix 2026-06-08)
    //
    // Backend `context_detail_descriptor` raisea "context not found" para
    // actores `person` (sólo aplica a contextos colectivos). Renderizamos un
    // home personal con drill-downs a las vistas existentes de Profile.

    @ViewBuilder
    private var personalSpaceContent: some View {
        List {
            // Hero
            Section {
                HStack(spacing: 14) {
                    Image(systemName: context.symbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 56, height: 56)
                        .background(Theme.Tint.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mi espacio")
                            .font(.title3.bold())
                            .foregroundStyle(Theme.Text.primary)
                        Text("Tu actividad, recursos y compromisos")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
            }

            // Attention items para el actor personal (filtrados por contextActorId == personal actor).
            let personalAttention = contextAttentionItems
            if !personalAttention.isEmpty {
                Section {
                    ForEach(personalAttention.prefix(3)) { item in
                        Button {
                            presentedAttention = AttentionDispatcher.destination(for: item)
                        } label: {
                            attentionRow(item)
                        }
                    }
                    if personalAttention.count > 3 {
                        Button {
                            isShowingAllAttention = true
                        } label: {
                            Label("Ver todos los pendientes (\(personalAttention.count))", systemImage: "list.bullet")
                        }
                    }
                } header: {
                    Text("Atención")
                }
            }

            // Drill-downs a vistas personales.
            Section {
                NavigationLink {
                    MyActivityFeedView(container: container)
                } label: {
                    Label("Mi actividad", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    MyResourcesView(container: container)
                } label: {
                    Label("Mis recursos", systemImage: "shippingbox.fill")
                }
                NavigationLink {
                    MySubscriptionsView(container: container)
                } label: {
                    Label("Mis suscripciones", systemImage: "bookmark.fill")
                }
                NavigationLink {
                    MyTrustNetworkView(container: container)
                } label: {
                    Label("Mi red de confianza", systemImage: "person.line.dotted.person")
                }
            } header: {
                Text("Tus cosas")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Descriptor content (R.5V.4 — List + Section, contextos colectivos)

    @ViewBuilder
    private func descriptorContent(_ d: ContextDetailDescriptor) -> some View {
        let availableTabs = Tab.allCases.filter { tab in
            tab.sectionKeys.contains { sectionKey in
                d.sections.contains { $0.sectionKey == sectionKey && $0.visible }
            }
        }
        List {
            tabSections(d, tab: effectiveTab(availableTabs))
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !context.isPersonal && !hierarchyStore.ancestors.isEmpty {
                    BreadcrumbView(
                        context: context,
                        ancestors: hierarchyStore.ancestors,
                        contextStore: container.contextStore
                    )
                }
                if availableTabs.count > 1 {
                    Picker("Vista", selection: $selectedTab) {
                        ForEach(availableTabs) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .background(.bar)
        }
        .onAppear {
            if !availableTabs.contains(selectedTab), let first = availableTabs.first {
                selectedTab = first
            }
        }
    }

    private func effectiveTab(_ available: [Tab]) -> Tab {
        available.contains(selectedTab) ? selectedTab : (available.first ?? .overview)
    }

    // MARK: - Tab dispatch

    @ViewBuilder
    private func tabSections(_ d: ContextDetailDescriptor, tab: Tab) -> some View {
        switch tab {
        case .overview:  overviewSections(d)
        case .people:    peopleSections(d)
        case .resources: resourcesSections(d)
        case .money:     moneySections(d)
        case .more:      moreSections(d)
        }
    }

    // MARK: - Overview tab (R.5V.3A — jerarquía firmada)
    //
    // Orden obligatorio:
    //   1. Hero          (RuulDetailHero con métricas como chips)
    //   2. Atención      (domina visualmente cuando hay items)
    //   3. Conflicts     (R.5B)
    //   4. Dashboard     (widgets filtrados — sin next_event/balance)
    //   5. Próximo evento (bloque dedicado, fuera del Dashboard)
    //   6. Balance        (bloque dedicado, fuera del Dashboard)
    //   7. Espacios hijos (carousel)
    //   8. Actividad reciente (máximo 3)
    //
    // resumenSection se elimina: las métricas viven en chips del Hero.

    @ViewBuilder
    private func overviewSections(_ d: ContextDetailDescriptor) -> some View {
        heroSection(d)
        attentionSection
        if d.conflicts.hasOpenConflicts {
            conflictsSection(summary: d.conflicts, list: conflictsList)
        }
        let filteredWidgets = overviewDashboardWidgets(d.widgets, descriptor: d)
        if !filteredWidgets.isEmpty {
            dashboardSection(filteredWidgets)
        }
        if hasNextEventWidget(d.widgets) {
            nextEventSection
        }
        if !d.moneyPreview.myBalanceByCurrency.isEmpty {
            balanceSection(d.moneyPreview)
        }
        if !d.childContextsPreview.isEmpty {
            childrenSection(d.childContextsPreview)
        }
        if !d.activityPreview.isEmpty {
            activitySection(d.activityPreview)
        }
    }

    // MARK: - Hero (R.5V.3A)

    @ViewBuilder
    private func heroSection(_ d: ContextDetailDescriptor) -> some View {
        Section {
            RuulDetailHero(
                title: context.isPersonal ? "Mi espacio" : (d.contextDisplayName ?? context.displayName),
                subtitle: heroSubtitle(d),
                systemImage: context.symbolName,
                tint: Theme.Tint.primary,
                chips: heroChips(d.metrics)
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func heroSubtitle(_ d: ContextDetailDescriptor) -> String? {
        if context.isPersonal { return "Tu actividad, recursos y compromisos" }
        return contextSubtypeLabel(context.subtype)
    }

    private func contextSubtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "trip":         return "Viaje"
        case "project":      return "Proyecto"
        case "trust":        return "Fideicomiso"
        case "friend_group": return "Grupo"
        case "company":      return "Empresa"
        default:             return subtype.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func heroChips(_ m: ContextMetrics) -> [String] {
        var chips: [String] = []
        if m.memberCount > 0 {
            chips.append("\(m.memberCount) \(m.memberCount == 1 ? "miembro" : "miembros")")
        }
        let resourceTotal = m.resourceCountByClass.values.reduce(0, +)
        if resourceTotal > 0 {
            chips.append("\(resourceTotal) \(resourceTotal == 1 ? "recurso" : "recursos")")
        }
        let pending = m.openObligations + m.pendingDecisions
        if pending > 0 {
            chips.append("\(pending) \(pending == 1 ? "pendiente" : "pendientes")")
        }
        return chips
    }

    // MARK: - Widget filtering (R.5V.3A + .fix)
    //
    // 1. Widgets que viven en bloques dedicados se excluyen del Dashboard:
    //    next_event, cash_balance, budget_progress, recent_activity.
    // 2. Widgets cuyas métricas ya viven en chips del Hero se excluyen:
    //    member_count_summary, open_decisions, open_obligations.
    // 3. Widgets con dato medible == 0 se ocultan (anti placeholder técnico):
    //    settlement_status sin open_settlements.
    //
    // Si después del filtro la sección queda vacía, no se renderiza.

    private func overviewDashboardWidgets(_ widgets: [ContextWidget], descriptor d: ContextDetailDescriptor) -> [ContextWidget] {
        widgets.filter { w in
            switch w.widgetKey {
            case "next_event",
                 "cash_balance",
                 "budget_progress",
                 "recent_activity",
                 "member_count_summary",
                 "open_decisions",
                 "open_obligations":
                return false
            case "settlement_status":
                return d.moneyPreview.openSettlements > 0
            default:
                return true
            }
        }
    }

    private func hasNextEventWidget(_ widgets: [ContextWidget]) -> Bool {
        widgets.contains { $0.widgetKey == "next_event" }
    }

    // MARK: - Attention

    private var contextAttentionItems: [AttentionItem] {
        container.attentionInboxStore.items.filter { $0.contextActorId == context.id }
    }

    @ViewBuilder
    private var attentionSection: some View {
        let items = contextAttentionItems
        Section {
            if items.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo al día").font(.callout.weight(.medium))
                        Text("Sin pendientes en este contexto")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
            } else {
                ForEach(items.prefix(3)) { item in
                    Button {
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    } label: {
                        attentionRow(item)
                    }
                }
                if items.count > 3 {
                    Button {
                        isShowingAllAttention = true
                    } label: {
                        Label("Ver todos los pendientes (\(items.count))", systemImage: "list.bullet")
                    }
                }
            }
        } header: {
            Text("Atención")
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: AttentionPresentation.symbol(for: item.kind))
                .foregroundStyle(attentionPriorityTint(item.derivedPriority))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(AttentionPresentation.ctaLabel(for: item.kind))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
    }

    private func attentionPriorityTint(_ priority: AttentionPriority) -> Color {
        switch priority {
        case .critical: return Theme.Tint.critical
        case .high:     return Theme.Tint.warning
        case .normal:   return Theme.Tint.info
        case .low:      return Theme.Text.tertiary
        }
    }

    // MARK: - Conflicts (R.5B)

    @ViewBuilder
    private func conflictsSection(summary: ContextConflictsSummary, list: ContextConflictList) -> some View {
        let open = summary.openCount
        let critical = summary.criticalCount
        Section {
            ForEach(list.items.prefix(4)) { item in
                conflictRow(item)
            }
            if list.items.count > 4 || list.items.count < open {
                NavigationLink {
                    ContextConflictsListView(contextActorId: contextId, context: context, container: container)
                } label: {
                    Label(
                        list.items.count < open ? "Ver \(open) conflictos" : "Ver todos (\(open))",
                        systemImage: "list.bullet"
                    )
                }
            }
        } header: {
            Text("Conflictos abiertos")
        } footer: {
            Text(conflictsSubtitle(open: open, critical: critical))
        }
    }

    @ViewBuilder
    private func conflictRow(_ item: ContextConflictItem) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                ResourceDetailViewV2(resourceId: item.resourceId, context: context, container: container)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: contextConflictSeverityIcon(item.severity))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(contextConflictSeverityTint(item.severity))
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: item.severity == "critical"
                        )
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.conflictTypeDisplay ?? item.conflictType)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        Text(item.resourceDisplayName ?? "Recurso")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            Button {
                guard !isResolvingContextConflict else { return }
                pendingContextConflict = item
                isShowingContextConflictDialog = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.Text.secondary)
                    .padding(.leading, 4)
            }
            .buttonStyle(.borderless)
            .disabled(isResolvingContextConflict)
        }
    }

    // MARK: - Dashboard (widgets)

    @ViewBuilder
    private func dashboardSection(_ widgets: [ContextWidget]) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                // R.5V.Glass.C2 founder feedback — mismo glass que childrenSection.
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(widgets) { widget in
                            contextWidgetCard(widget)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Dashboard")
        }
    }

    @ViewBuilder
    private func contextWidgetCard(_ widget: ContextWidget) -> some View {
        if contextWidgetDestinationKey(widget.widgetKey) != nil {
            NavigationLink {
                contextWidgetDestination(widgetKey: widget.widgetKey)
            } label: {
                contextWidgetCardBody(widget, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            contextWidgetCardBody(widget, tappable: false)
        }
    }

    /// 2026-06-09 — headline computado por widget key consumiendo metrics +
    /// previews del descriptor. Antes el card era plástico (icon + título
    /// solamente). Si no hay data para ese widget, retorna nil y cae al
    /// layout plástico anterior.
    private func contextWidgetHeadline(_ widget: ContextWidget) -> (value: String, tint: Color)? {
        guard let d = store.descriptor else { return nil }
        switch widget.widgetKey {
        case "cash_balance":
            // Prefer my net balance del caller; sumando currencies (ya con signo).
            let sum = d.moneyPreview.myBalanceByCurrency.values.reduce(0, +)
            if sum != 0, let currency = d.moneyPreview.myBalanceByCurrency.keys.first {
                let tint: Color = sum >= 0 ? Theme.Tint.success : Theme.Tint.critical
                return (formatCurrency(sum, currency: currency), tint)
            }
        case "open_obligations":
            if d.metrics.openObligations > 0 {
                return ("\(d.metrics.openObligations)", Theme.Tint.warning)
            }
        case "open_decisions":
            if d.metrics.pendingDecisions > 0 {
                return ("\(d.metrics.pendingDecisions)", .purple)
            }
        case "member_count_summary":
            if d.metrics.memberCount > 0 {
                return ("\(d.metrics.memberCount)", Theme.Tint.info)
            }
        case "critical_resources":
            let total = d.metrics.resourceCountByClass.values.reduce(0, +)
            if total > 0 {
                return ("\(total)", Theme.Tint.warning)
            }
        case "recent_activity":
            if d.activityPreview.count > 0 {
                return ("\(d.activityPreview.count)", Theme.Tint.info)
            }
        case "next_event":
            if let first = d.eventsPreview.first, let date = first.startsAt {
                if Calendar.current.isDateInToday(date) { return ("Hoy", Theme.Tint.warning) }
                if Calendar.current.isDateInTomorrow(date) { return ("Mañana", Theme.Tint.warning) }
                return (date.formatted(.dateTime.day().month(.abbreviated)), Theme.Tint.primary)
            }
        case "settlement_status":
            if d.moneyPreview.openSettlements > 0 {
                return ("\(d.moneyPreview.openSettlements)", Theme.Tint.warning)
            }
        default:
            break
        }
        return nil
    }

    @ViewBuilder
    private func contextWidgetCardBody(_ widget: ContextWidget, tappable: Bool) -> some View {
        let headline = contextWidgetHeadline(widget)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(headline?.tint ?? Theme.Tint.primary)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let headline {
                Text(headline.value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(headline.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(widget.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(2)
            } else {
                Text(widget.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: 150, height: 130, alignment: .topLeading)
        .padding(14)
        // R.5V.Glass.C2 founder feedback — Liquid Glass como en childrenSection.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    // MARK: - Próximo evento (R.5V.3A — bloque dedicado, fuera del Dashboard)

    @ViewBuilder
    private var nextEventSection: some View {
        Section {
            NavigationLink {
                EventsListView(context: context, container: container)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ver próximos eventos")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Calendario del espacio")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(Theme.Tint.info)
                }
            }
        } header: {
            Text("Próximo evento")
        }
    }

    // MARK: - Balance (R.5V.3A — bloque dedicado en Overview)

    @ViewBuilder
    private func balanceSection(_ money: ContextMoneyPreview) -> some View {
        Section {
            ForEach(money.myBalanceByCurrency.sorted(by: { $0.key < $1.key }), id: \.key) { (currency, net) in
                NavigationLink {
                    MoneyHomeView(context: context, container: container)
                } label: {
                    LabeledContent {
                        Text(formatCurrency(net, currency: currency))
                            .font(.callout.bold().monospacedDigit())
                            .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                    } label: {
                        Label(
                            net >= 0 ? "Te deben" : "Debes",
                            systemImage: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
                        )
                    }
                }
            }
        } header: {
            Text("Mi balance")
        }
    }

    private func contextWidgetDestinationKey(_ key: String) -> String? {
        switch key {
        case "cash_balance", "budget_progress", "open_obligations":
            return "money"
        case "critical_resources":   return "resources"
        case "member_count_summary": return "members"
        case "next_event":           return "events"
        case "open_decisions":       return "decisions"
        case "recent_activity":      return "activity"
        case "settlement_status":    return "settlement"
        case "upcoming_reservations": return "reservations"
        default:                     return nil
        }
    }

    @ViewBuilder
    private func contextWidgetDestination(widgetKey: String) -> some View {
        switch contextWidgetDestinationKey(widgetKey) {
        case "money":        MoneyHomeView(context: context, container: container)
        case "resources":    ResourcesListView(context: context, container: container)
        case "members":      MembersListView(context: context, container: container)
        case "events":       EventsListView(context: context, container: container)
        case "decisions":    DecisionsListView(context: context, container: container)
        case "activity":     ActivityFeedView(context: context, container: container)
        case "settlement":   SettlementView(context: context, container: container)
        case "reservations": ContextReservationsView(context: context, container: container)
        default:             EmptyView()
        }
    }

    // MARK: - Children (subcontextos)

    @ViewBuilder
    private func childrenSection(_ children: [ContextChildPreview]) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                // R.5V.Glass.C2 — GlassEffectContainer permite morphing entre
                // los cards de hijos cuando se acercan/cruzan durante scroll.
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(children) { child in
                            childDescriptorCard(child)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Espacios dentro de \(context.displayName)")
        }
    }

    @ViewBuilder
    private func childDescriptorCard(_ child: ContextChildPreview) -> some View {
        if let target = container.contextStore.availableContexts.first(where: { $0.id == child.id }) {
            NavigationLink(value: target) {
                childDescriptorCardLabel(child)
            }
            .buttonStyle(.plain)
        } else {
            childDescriptorCardLabel(child).opacity(0.5)
        }
    }

    @ViewBuilder
    private func childDescriptorCardLabel(_ child: ContextChildPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: childSymbolName(child))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Tint.primary)
                    .frame(width: 40, height: 40)
                    .background(Theme.Tint.primary.opacity(0.15), in: Circle())
                Spacer()
                if child.visibility == "private" {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            Text(child.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(childSubtypeLabel(child.actorSubtype ?? "generic"))
                .font(.caption2)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, height: 150, alignment: .topLeading)
        .padding(14)
        // R.5V.Glass.C2 — glassEffect interactivo dentro del GlassEffectContainer
        // del childrenSection para que el morphing funcione al scroll.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    private func childSymbolName(_ child: ContextChildPreview) -> String {
        switch child.actorSubtype {
        case "family":       return "house.fill"
        case "trip":         return "airplane"
        case "project":      return "rectangle.stack.fill"
        case "trust":        return "checkmark.shield.fill"
        case "community":    return "person.3.fill"
        case "friend_group": return "person.2.fill"
        case "company":      return "building.2.fill"
        default:             return "circle.grid.cross.fill"
        }
    }

    private func childSubtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "trip":         return "Viaje"
        case "project":      return "Proyecto"
        case "trust":        return "Fideicomiso"
        case "friend_group": return "Grupo"
        case "company":      return "Empresa"
        default:             return "Contexto"
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private func activitySection(_ events: [ActivityPreviewEvent]) -> some View {
        Section {
            ForEach(events.prefix(3)) { ev in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activityEventLabel(ev.eventType))
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                        if let when = ev.occurredAt {
                            Text(when.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: activityEventIcon(ev.eventType))
                        .foregroundStyle(activityEventTint(ev.eventType))
                }
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

    /// SF Symbol consistente por familia de event_type. Fallback a `bolt.circle`.
    private func activityEventIcon(_ eventType: String) -> String {
        if eventType.hasPrefix("resource.")  { return "shippingbox.fill" }
        if eventType.hasPrefix("event.")     { return "calendar" }
        if eventType.hasPrefix("decision.")  { return "checkmark.bubble.fill" }
        if eventType.hasPrefix("obligation.") || eventType.hasPrefix("fine.") { return "doc.text.fill" }
        if eventType.hasPrefix("expense.")   { return "dollarsign.circle.fill" }
        if eventType.hasPrefix("settlement.") { return "creditcard.fill" }
        if eventType.hasPrefix("reservation.") { return "calendar.badge.clock" }
        if eventType.hasPrefix("document.")  { return "doc.text" }
        if eventType.hasPrefix("right.")     { return "key.fill" }
        if eventType.hasPrefix("invite.") || eventType.hasPrefix("membership.") { return "person.badge.plus" }
        if eventType.hasPrefix("context.")   { return "rectangle.split.2x1.fill" }
        if eventType.hasPrefix("rule.")      { return "ruler.fill" }
        if eventType.hasPrefix("conflict.") || eventType.contains(".conflict_") { return "exclamationmark.triangle.fill" }
        if eventType.hasPrefix("split.")     { return "divide.circle.fill" }
        if eventType.hasPrefix("subscription.") { return "bookmark.fill" }
        if eventType.hasPrefix("governance.") { return "checkmark.shield.fill" }
        return "bolt.circle"
    }

    /// Tint semántico para activity icon: dinero/conflict/governance diferenciados.
    private func activityEventTint(_ eventType: String) -> Color {
        if eventType.hasPrefix("expense.") || eventType.hasPrefix("settlement.") ||
           eventType.hasPrefix("split.") || eventType.contains("fine.") { return Theme.Tint.success }
        if eventType.hasPrefix("conflict.") || eventType.contains(".conflict_") {
            return Theme.Tint.warning
        }
        if eventType.hasPrefix("decision.") || eventType.hasPrefix("governance.") {
            return .purple
        }
        if eventType.hasPrefix("rule.") { return Theme.Tint.info }
        return Theme.Tint.primary
    }

    /// Label friendly para event_type (e.g. `resource.created` → `Recurso · creado`).
    private func activityEventLabel(_ eventType: String) -> String {
        let parts = eventType.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return eventType }
        let domain = activityDomainLabel(parts[0])
        let action = parts[1]
            .replacingOccurrences(of: "_", with: " ")
        return "\(domain) · \(action)"
    }

    private func activityDomainLabel(_ domain: String) -> String {
        switch domain {
        case "resource":     return "Recurso"
        case "event":        return "Evento"
        case "decision":     return "Decisión"
        case "obligation":   return "Compromiso"
        case "fine":         return "Multa"
        case "expense":      return "Gasto"
        case "settlement":   return "Liquidación"
        case "reservation":  return "Reserva"
        case "document":     return "Documento"
        case "right":        return "Derecho"
        case "invite":       return "Invitación"
        case "membership":   return "Membresía"
        case "context":      return "Contexto"
        case "rule":         return "Regla"
        case "split":        return "Split"
        case "subscription": return "Suscripción"
        case "governance":   return "Gobierno"
        default:             return domain.capitalized
        }
    }

    // MARK: - People tab
    //
    // P0 fix 2026-06-08: removidos NavigationLinks redundantes en member rows
    // y role rows — todos pusheaban a la MISMA `MembersListView`. Member rows
    // ahora pasivos (preview info), UN solo CTA al final pushea la lista
    // completa con drill-down a MemberDetailView. Roles también pasivos.

    @ViewBuilder
    private func peopleSections(_ d: ContextDetailDescriptor) -> some View {
        Section {
            if d.membersPreview.isEmpty {
                Label("Sin miembros para mostrar", systemImage: "person.2")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(d.membersPreview) { m in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Theme.Tint.primary.opacity(0.15))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(m.displayName.first.map { String($0) } ?? "?")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Theme.Tint.primary)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(membershipTypeLabel(m.membershipType))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                        Spacer()
                    }
                }
                NavigationLink {
                    MembersListView(context: context, container: container)
                } label: {
                    Label(
                        d.metrics.memberCount > d.membersPreview.count
                            ? "Ver todos los miembros (\(d.metrics.memberCount))"
                            : "Ver detalle de miembros",
                        systemImage: "person.3.fill"
                    )
                }
            }
        } header: {
            Text("Miembros (\(d.metrics.memberCount))")
        }

        if !d.roles.isEmpty {
            Section {
                ForEach(d.roles) { role in
                    LabeledContent {
                        Text("\(role.memberCount)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.Text.primary)
                    } label: {
                        Label(role.displayName, systemImage: roleIcon(role.roleKey))
                    }
                }
            } header: {
                Text("Roles")
            } footer: {
                Text("Los roles se asignan desde el detalle de cada miembro.")
            }
        }
    }

    /// Friendly label para membership_type del descriptor.
    private func membershipTypeLabel(_ type: String) -> String {
        switch type {
        case "member":   return "Miembro"
        case "admin":    return "Administrador"
        case "founder":  return "Fundador"
        case "guest":    return "Invitado"
        case "viewer":   return "Observador"
        default:         return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// SF Symbol per role_key. Heurística por keyword.
    private func roleIcon(_ roleKey: String) -> String {
        let k = roleKey.lowercased()
        if k.contains("founder") || k.contains("owner") { return "crown.fill" }
        if k.contains("admin") { return "person.badge.key.fill" }
        if k.contains("manager") || k.contains("custodian") { return "key.fill" }
        if k.contains("guest") || k.contains("viewer") { return "eye.fill" }
        if k.contains("treasurer") || k.contains("financ") { return "creditcard.fill" }
        return "person.badge.shield.checkmark.fill"
    }

    // MARK: - Resources tab

    @ViewBuilder
    private func resourcesSections(_ d: ContextDetailDescriptor) -> some View {
        if d.resourcesPreview.isEmpty {
            Section {
                Label("Sin recursos en este contexto", systemImage: "shippingbox")
                    .foregroundStyle(Theme.Text.secondary)
            } header: {
                Text("Recursos")
            } footer: {
                Text("Crea un recurso desde el botón ＋ del toolbar del contexto.")
            }
        } else {
            // R.5A.B.0 class catalog (founder-seeded 17 classes). Header label
            // user-friendly + icon de SF Symbols por class.
            let byClass = Dictionary(grouping: d.resourcesPreview) { $0.classKey ?? "generic" }
            ForEach(byClass.keys.sorted(), id: \.self) { classKey in
                if let items = byClass[classKey] {
                    Section {
                        ForEach(items) { r in
                            NavigationLink {
                                ResourceDetailViewV2(resourceId: r.resourceId, context: context, container: container)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.displayName)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(Theme.Text.primary)
                                            .lineLimit(1)
                                        if let sub = r.subtypeKey {
                                            Text(sub.replacingOccurrences(of: "_", with: " ").capitalized)
                                                .font(.caption)
                                                .foregroundStyle(Theme.Text.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: resourceClassIcon(r.classKey ?? "generic"))
                                        .foregroundStyle(Theme.Tint.primary)
                                }
                            }
                        }
                    } header: {
                        Label(
                            resourceClassLabel(classKey),
                            systemImage: resourceClassIcon(classKey)
                        )
                    }
                }
            }
        }
    }

    /// SF Symbol por R.5A.B.0 class_key (17 classes founder-seeded).
    private func resourceClassIcon(_ classKey: String) -> String {
        switch classKey {
        case "real_estate":    return "house.fill"
        case "vehicle":        return "car.fill"
        case "equipment":      return "wrench.and.screwdriver.fill"
        case "financial":      return "banknote.fill"
        case "document":       return "doc.text.fill"
        case "event":          return "calendar"
        case "service":        return "bag.fill"
        case "agreement":      return "doc.plaintext.fill"
        case "digital_asset":  return "externaldrive.fill"
        case "right":          return "key.fill"
        case "membership":     return "person.crop.circle.fill"
        case "space":          return "square.split.bottomrightquarter.fill"
        case "money":          return "dollarsign.circle.fill"
        case "obligation":     return "doc.text.below.ecg.fill"
        case "decision":       return "checkmark.bubble.fill"
        case "rule":           return "ruler.fill"
        case "generic":        return "shippingbox.fill"
        default:               return "shippingbox.fill"
        }
    }

    /// Label friendly por class_key.
    private func resourceClassLabel(_ classKey: String) -> String {
        switch classKey {
        case "real_estate":    return "Inmuebles"
        case "vehicle":        return "Vehículos"
        case "equipment":      return "Equipo"
        case "financial":      return "Financiero"
        case "document":       return "Documentos"
        case "event":          return "Eventos"
        case "service":        return "Servicios"
        case "agreement":      return "Acuerdos"
        case "digital_asset":  return "Activos digitales"
        case "right":          return "Derechos"
        case "membership":     return "Membresías"
        case "space":          return "Espacios"
        case "money":          return "Dinero"
        case "obligation":     return "Compromisos"
        case "decision":       return "Decisiones"
        case "rule":           return "Reglas"
        case "generic":        return "Generales"
        default:               return classKey.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - Money tab

    @ViewBuilder
    private func moneySections(_ d: ContextDetailDescriptor) -> some View {
        if !d.moneyPreview.myBalanceByCurrency.isEmpty {
            Section {
                ForEach(d.moneyPreview.myBalanceByCurrency.sorted(by: { $0.key < $1.key }), id: \.key) { (currency, net) in
                    LabeledContent {
                        Text(formatCurrency(net, currency: currency))
                            .font(.callout.bold().monospacedDigit())
                            .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                    } label: {
                        Label(currency, systemImage: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                    }
                }
            } header: {
                Text("Mi saldo")
            } footer: {
                Text("Saldo positivo = te deben. Saldo negativo = debes.")
            }
        }

        Section {
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                LabeledContent {
                    Text("\(d.moneyPreview.openSettlements)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(d.moneyPreview.openSettlements > 0 ? Theme.Tint.warning : Theme.Text.primary)
                } label: {
                    Label("Liquidaciones abiertas", systemImage: "creditcard.fill")
                }
            }
        }

        Section {
            if d.obligationsPreview.isEmpty {
                Label("Sin obligaciones pendientes", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(d.obligationsPreview) { o in
                    NavigationLink {
                        ObligationDetailView(obligationId: o.obligationId, context: context, container: container)
                    } label: {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(obligationKindLabel(o.kind))
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(Theme.Text.primary)
                                    if let s = o.status {
                                        Text(obligationStatusLabel(s))
                                            .font(.caption)
                                            .foregroundStyle(Theme.Text.tertiary)
                                    }
                                }
                                Spacer()
                                if let amount = o.amount, let cur = o.currency {
                                    Text("\(Int(amount)) \(cur)")
                                        .font(.callout.bold().monospacedDigit())
                                        .foregroundStyle(Theme.Text.primary)
                                }
                            }
                        } icon: {
                            Image(systemName: obligationKindIcon(o.kind))
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
        } header: {
            Text("Obligaciones recientes")
        }
    }

    private func obligationKindIcon(_ kind: String?) -> String {
        switch kind {
        case "money":       return "dollarsign.circle.fill"
        case "action":      return "checklist"
        case "approval":    return "checkmark.seal.fill"
        case "delivery":    return "shippingbox.fill"
        case "attendance":  return "person.crop.circle.badge.checkmark.fill"
        case "document":    return "doc.text.fill"
        case "reservation": return "calendar.badge.clock"
        default:            return "doc.text.below.ecg.fill"
        }
    }

    private func obligationKindLabel(_ kind: String?) -> String {
        switch kind {
        case "money":       return "Dinero"
        case "action":      return "Acción"
        case "approval":    return "Aprobación"
        case "delivery":    return "Entrega"
        case "attendance":  return "Asistencia"
        case "document":    return "Documento"
        case "reservation": return "Reservación"
        default:            return "Compromiso"
        }
    }

    private func obligationStatusLabel(_ status: String) -> String {
        switch status {
        case "open":        return "Abierta"
        case "accepted":    return "Aceptada"
        case "in_progress": return "En progreso"
        case "completed":   return "Cumplida"
        case "settled":     return "Liquidada"
        case "cancelled":   return "Cancelada"
        case "expired":     return "Vencida"
        default:            return status.capitalized
        }
    }

    private func formatCurrency(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(Int(value)) \(currency)"
    }

    // MARK: - More tab

    @ViewBuilder
    private func moreSections(_ d: ContextDetailDescriptor) -> some View {
        if !d.pendingInvitationsPreview.isEmpty {
            Section {
                ForEach(d.pendingInvitationsPreview) { inv in
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(Theme.Tint.info)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inv.code)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Theme.Text.primary)
                            Text(inviteUsageLabel(inv))
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                        Spacer()
                        if let exp = inv.expiresAt {
                            Text(exp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
            } header: {
                Text("Invitaciones activas (\(d.pendingInvitationsPreview.count))")
            }
        }

        let moreSections = d.sections.filter {
            $0.visible && Tab.more.sectionKeys.contains($0.sectionKey)
        }
        Section {
            if moreSections.isEmpty {
                Label("Sin más secciones", systemImage: "ellipsis.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(moreSections) { section in
                    NavigationLink {
                        moreSectionDestination(section.sectionKey)
                    } label: {
                        Label(section.displayName, systemImage: section.icon ?? "circle")
                    }
                }
            }
        } header: {
            Text("Secciones")
        }

        if !d.permissions.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(d.permissions, id: \.self) { p in
                            chipBadge(p, tint: .purple)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Mis permisos (\(d.permissions.count))")
            }
        }
    }

    private func inviteUsageLabel(_ inv: ContextInvitePreview) -> String {
        if let max = inv.maxUses {
            return "\(inv.usedCount) / \(max) usos"
        }
        return "\(inv.usedCount) usos · ilimitado"
    }

    @ViewBuilder
    private func moreSectionDestination(_ sectionKey: String) -> some View {
        switch sectionKey {
        case "calendar":   EventsListView(context: context, container: container)
        case "governance": DecisionsListView(context: context, container: container)
        case "documents":  ContextDocumentsListView(context: context, container: container)
        case "activity":   ActivityFeedView(context: context, container: container)
        case "settings":   ContextSettingsView(context: context, container: container)
        default:           ActivityFeedView(context: context, container: container)
        }
    }

    // MARK: - Toolbar (P0 fix 2026-06-08 — acciones específicas por contexto)
    //
    // Personal context: sin acciones de gestión.
    // Collective context:
    //   - Trailing "+": Menu con descriptor.actions (create_resource, invite,
    //     record_expense, create_decision, create_event, create_rule, create_child).
    //   - Trailing "ellipsis": Menu con drill-downs específicos del contexto
    //     (Reglas, Configuración).

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if context.isPersonal {
            // Personal context — sin acciones de gestión.
            EmptyToolbarContent()
        } else {
            if let actions = store.descriptor?.actions, !actions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    quickActionsMenu(actions: actions)
                }
                // R.5V.Toolbar.Spacers — separa "+" (quick actions) del
                // "ellipsis" (más opciones) en cápsulas Liquid Glass distintas.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        pushedActionDestination = .rules
                    } label: {
                        Label("Reglas", systemImage: "ruler.fill")
                    }
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Configuración", systemImage: "gearshape.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Más opciones del contexto")
            }
        }
    }

    /// Empty toolbar content para gating del personal sin warnings.
    private struct EmptyToolbarContent: ToolbarContent {
        var body: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) { EmptyView() }
        }
    }

    @ViewBuilder
    private func quickActionsMenu(actions: [AvailableAction]) -> some View {
        // P0 fix 2026-06-08 — acciones agrupadas por descriptor.section.
        // Apple HIG: Menu con Sections para clusters semánticos
        // (Crear / Registrar / Personas / Gobierno / ...). Orden estable por
        // section priority + label alfabético dentro de cada section.
        let grouped = Dictionary(grouping: actions, by: { $0.section })
        let orderedSections = grouped.keys.sorted(by: { contextActionSectionOrder($0) < contextActionSectionOrder($1) })

        Menu {
            ForEach(orderedSections, id: \.self) { sectionKey in
                if let sectionActions = grouped[sectionKey], !sectionActions.isEmpty {
                    Section(contextActionSectionLabel(sectionKey)) {
                        ForEach(sectionActions.sorted(by: { $0.label < $1.label })) { action in
                            let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
                            Button {
                                quickActionsRouter.open(ActionRouter.destination(for: action, in: .context(context.id)))
                            } label: {
                                Label(action.label, systemImage: presentation.symbolName)
                            }
                            .disabled(!action.enabled)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
        .accessibilityLabel("Acciones del contexto")
    }

    /// Orden estable de sections del context_detail_descriptor.actions.
    /// Lower number = higher priority (aparece primero en el Menu).
    private func contextActionSectionOrder(_ section: String) -> Int {
        switch section {
        case "create", "creation":    return 0
        case "money", "monetary":     return 1
        case "people", "members":     return 2
        case "governance", "rules":   return 3
        case "events", "calendar":    return 4
        case "resources":             return 5
        case "documents":             return 6
        case "subcontexts", "children": return 7
        case "settings":              return 9
        default:                      return 8
        }
    }

    /// Friendly label para secciones del Menu.
    private func contextActionSectionLabel(_ section: String) -> String {
        switch section {
        case "create", "creation":     return "Crear"
        case "money", "monetary":      return "Dinero"
        case "people", "members":      return "Personas"
        case "governance":             return "Gobierno"
        case "rules":                  return "Reglas"
        case "events", "calendar":     return "Eventos"
        case "resources":              return "Recursos"
        case "documents":              return "Documentos"
        case "subcontexts", "children": return "Espacios hijos"
        case "settings":               return "Configuración"
        default:                       return section.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func handleQuickAction(_ destination: ActionDestination) {
        switch destination.actionKey {
        case "create_resource":      pushedActionDestination = .resources
        case "create_event":         pushedActionDestination = .events
        case "create_decision":      pushedActionDestination = .decisions
        case "record_expense":       pushedActionDestination = .money
        case "invite_member":        pushedActionDestination = .members
        case "create_rule":          pushedActionDestination = .rules
        case "create_child_context": isShowingCreateChild = true
        default: break
        }
    }

    // MARK: - Chips (helper compartido)

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }

    // MARK: - R.5B.5c — Conflict helpers (preservados intactos)

    private func conflictsSubtitle(open: Int, critical: Int) -> String {
        if critical > 0 {
            return critical == open
                ? "\(critical) crítico\(critical == 1 ? "" : "s")"
                : "\(critical) crítico\(critical == 1 ? "" : "s") · \(open) abierto\(open == 1 ? "" : "s")"
        }
        return "\(open) abierto\(open == 1 ? "" : "s")"
    }

    fileprivate func contextConflictSeverityIcon(_ severity: String) -> String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning":  return "exclamationmark.triangle.fill"
        case "info":     return "info.circle.fill"
        default:         return "exclamationmark.circle"
        }
    }

    fileprivate func contextConflictSeverityTint(_ severity: String) -> Color {
        switch severity {
        case "critical": return Theme.Tint.critical
        case "warning":  return Theme.Tint.warning
        case "info":     return Theme.Tint.info
        default:         return Theme.Text.secondary
        }
    }

    fileprivate func contextConflictDialogMessage(_ item: ContextConflictItem) -> String {
        let action = item.recommendedActionKey ?? "resolve_resource_conflict"
        let recommended: String
        switch action {
        case "escalate_to_decision":
            recommended = "Recomendado: escalar a decisión."
        case "resolve_reservation_conflict", "resolve_resource_conflict":
            recommended = "Recomendado: resolver manualmente."
        default:
            recommended = ""
        }
        return ["¿Qué hacemos con este conflicto?", recommended]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func loadContextConflictsIfNeeded() async {
        guard let d = store.descriptor, d.conflicts.hasOpenConflicts else {
            conflictsList = .empty
            return
        }
        if didLoadConflictsForContext == contextId { return }
        await reloadContextConflicts()
    }

    func reloadContextConflicts() async {
        do {
            conflictsList = try await container.rpc.listContextConflicts(
                contextActorId: contextId, includeResolved: false
            )
            didLoadConflictsForContext = contextId
        } catch {
            // Silent — la card se queda con los items previos.
        }
    }

    fileprivate func resolveContextConflict(_ item: ContextConflictItem, kind: ResolveResourceConflictKind) {
        guard !isResolvingContextConflict else { return }
        isResolvingContextConflict = true
        Task { @MainActor in
            defer { isResolvingContextConflict = false }
            do {
                let result = try await container.rpc.resolveResourceConflict(
                    conflictId: item.conflictId,
                    kind: kind,
                    winnerActorId: nil,
                    payload: .object([:])
                )
                await reloadContextConflicts()
                await store.load(contextId: contextId)
                if result.noOp {
                    contextConflictAlert = ContextConflictsAlert(
                        title: "Sin cambios",
                        message: "El conflicto ya no estaba abierto."
                    )
                } else {
                    let title: String = {
                        switch kind {
                        case .manualResolution: return "Resuelto"
                        case .escalate:         return "Escalado"
                        case .dismiss:          return "Descartado"
                        }
                    }()
                    let message: String = {
                        switch kind {
                        case .manualResolution: return "El conflicto quedó resuelto."
                        case .escalate:
                            if let tmpl = result.templateKey {
                                return "Se creó una decisión (\(tmpl)) para resolver el conflicto."
                            }
                            return "Se creó una decisión para resolver el conflicto."
                        case .dismiss: return "El conflicto fue descartado."
                        }
                    }()
                    contextConflictAlert = ContextConflictsAlert(title: title, message: message)
                }
                isShowingContextConflictAlert = true
            } catch {
                contextConflictAlert = ContextConflictsAlert(
                    title: "No pudimos resolver",
                    message: UserFacingError.from(error).message
                )
                isShowingContextConflictAlert = true
            }
        }
    }
}

// MARK: - Sheet "Todos los pendientes" (V2)

private struct AllContextAttentionViewV2: View {
    let items: [AttentionItem]
    let onTap: (AttentionItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    onTap(item)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: AttentionPresentation.symbol(for: item.kind))
                            .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.medium))
                            Text(item.reason)
                                .font(.caption).foregroundStyle(Theme.Text.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pendientes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }
}

// MARK: - R.5B.5c — ContextConflictsAlert + ContextConflictsModifier

fileprivate struct ContextConflictsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Aísla confirmation dialog + alert fuera del body — preempt type-checker
/// timeout (heredado de R.5B.5b — el body ya tenía 13+ modifiers, R.5V.4 +1).
private struct ContextConflictsModifier: ViewModifier {
    @Binding var pendingConflict: ContextConflictItem?
    @Binding var isShowingDialog: Bool
    @Binding var alert: ContextConflictsAlert?
    @Binding var isShowingAlert: Bool
    let dialogMessage: (ContextConflictItem) -> String
    let onKind: (ContextConflictItem, ResolveResourceConflictKind) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingConflict?.conflictTypeDisplay ?? "Conflicto",
                isPresented: $isShowingDialog,
                titleVisibility: .visible,
                presenting: pendingConflict
            ) { item in
                Button("Resolver manualmente") { onKind(item, .manualResolution) }
                Button("Escalar a decisión")  { onKind(item, .escalate) }
                Button("Descartar", role: .destructive) { onKind(item, .dismiss) }
                Button("Cancelar", role: .cancel) {}
            } message: { item in
                Text(dialogMessage(item))
            }
            .alert(
                alert?.title ?? "",
                isPresented: $isShowingAlert,
                presenting: alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { a in
                Text(a.message)
            }
    }
}
