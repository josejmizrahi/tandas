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
    @State private var isShowingClassicSheet = false
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
        .navigationTitle(store.descriptor?.contextDisplayName ?? "Contexto")
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
            await store.load(contextId: contextId)
            await container.attentionInboxStore.load()
            if !context.isPersonal {
                await hierarchyStore.load(contextId: contextId)
            }
            await loadContextConflictsIfNeeded()
        }
        .refreshable {
            await store.load(contextId: contextId)
            await container.attentionInboxStore.load()
            if !context.isPersonal {
                await hierarchyStore.load(contextId: contextId)
            }
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
        .sheet(isPresented: $isShowingClassicSheet) {
            NavigationStack {
                ContextHomeView(context: context, container: container)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cerrar") { isShowingClassicSheet = false }
                        }
                    }
            }
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

    // MARK: - Descriptor content (R.5V.4 — List + Section)

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

    // MARK: - Overview tab

    @ViewBuilder
    private func overviewSections(_ d: ContextDetailDescriptor) -> some View {
        attentionSection
        if d.conflicts.hasOpenConflicts {
            conflictsSection(summary: d.conflicts, list: conflictsList)
        }
        resumenSection(d.metrics)
        if !d.widgets.isEmpty {
            dashboardSection(d.widgets)
        }
        if !d.childContextsPreview.isEmpty {
            childrenSection(d.childContextsPreview)
        }
        if !d.activityPreview.isEmpty {
            activitySection(d.activityPreview)
        }
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
                        .foregroundStyle(contextConflictSeverityTint(item.severity))
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

    // MARK: - Resumen (metrics)

    @ViewBuilder
    private func resumenSection(_ m: ContextMetrics) -> some View {
        Section {
            LabeledContent("Miembros", value: "\(m.memberCount)")
            LabeledContent("Decisiones pendientes", value: "\(m.pendingDecisions)")
            LabeledContent("Obligaciones abiertas", value: "\(m.openObligations)")
            if !m.resourceCountByClass.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(m.resourceCountByClass.sorted(by: { $0.value > $1.value }), id: \.key) { (key, count) in
                            chipBadge("\(count) \(key.replacingOccurrences(of: "_", with: " "))", tint: Theme.Tint.info)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Resumen")
        }
    }

    // MARK: - Dashboard (widgets)

    @ViewBuilder
    private func dashboardSection(_ widgets: [ContextWidget]) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(widgets) { widget in
                        contextWidgetCard(widget)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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

    @ViewBuilder
    private func contextWidgetCardBody(_ widget: ContextWidget, tappable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Tint.primary)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            Text(widget.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let src = widget.dataSourceKey {
                Text(src)
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: 150, height: 130, alignment: .topLeading)
        .padding(14)
        .background(Theme.Background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                HStack(spacing: 12) {
                    ForEach(children) { child in
                        childDescriptorCard(child)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
            Image(systemName: childSymbolName(child))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Tint.primary)
                .frame(width: 40, height: 40)
                .background(Theme.Tint.primary.opacity(0.12), in: Circle())
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
        .frame(width: 140, height: 140, alignment: .topLeading)
        .padding(14)
        .background(Theme.Background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            ForEach(events.prefix(5)) { ev in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bolt.circle")
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                        if let when = ev.occurredAt {
                            Text(when.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    Spacer()
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

    // MARK: - People tab

    @ViewBuilder
    private func peopleSections(_ d: ContextDetailDescriptor) -> some View {
        Section {
            if d.membersPreview.isEmpty {
                Label("Sin miembros para mostrar", systemImage: "person.2")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(d.membersPreview) { m in
                    NavigationLink {
                        MembersListView(context: context, container: container)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Theme.Tint.primary.opacity(0.12))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(m.displayName.first.map { String($0) } ?? "?")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Theme.Tint.primary)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName).font(.callout).foregroundStyle(Theme.Text.primary)
                                Text(m.membershipType).font(.caption).foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                NavigationLink {
                    MembersListView(context: context, container: container)
                } label: {
                    Label("Ver todos los miembros (\(d.metrics.memberCount))", systemImage: "person.3")
                }
            }
        } header: {
            Text("Miembros")
        }

        if !d.roles.isEmpty {
            Section {
                ForEach(d.roles) { role in
                    NavigationLink {
                        MembersListView(context: context, container: container)
                    } label: {
                        LabeledContent(role.displayName, value: "\(role.memberCount)")
                    }
                }
            } header: {
                Text("Roles")
            }
        }
    }

    // MARK: - Resources tab

    @ViewBuilder
    private func resourcesSections(_ d: ContextDetailDescriptor) -> some View {
        if d.resourcesPreview.isEmpty {
            Section {
                Label("Sin recursos en este contexto", systemImage: "cube")
                    .foregroundStyle(Theme.Text.secondary)
            } header: {
                Text("Recursos")
            } footer: {
                Text("Crea un recurso desde el botón ＋ del contexto.")
            }
        } else {
            let byClass = Dictionary(grouping: d.resourcesPreview) { $0.classKey ?? "generic" }
            ForEach(byClass.keys.sorted(), id: \.self) { classKey in
                if let items = byClass[classKey] {
                    Section {
                        ForEach(items) { r in
                            NavigationLink {
                                ResourceDetailViewV2(resourceId: r.resourceId, context: context, container: container)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "cube")
                                        .foregroundStyle(Theme.Tint.primary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.displayName).font(.callout).foregroundStyle(Theme.Text.primary)
                                        if let sub = r.subtypeKey {
                                            Text(sub.replacingOccurrences(of: "_", with: " "))
                                                .font(.caption)
                                                .foregroundStyle(Theme.Text.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        Text(classKey.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }
            }
        }
    }

    // MARK: - Money tab

    @ViewBuilder
    private func moneySections(_ d: ContextDetailDescriptor) -> some View {
        if !d.moneyPreview.myBalanceByCurrency.isEmpty {
            Section {
                ForEach(d.moneyPreview.myBalanceByCurrency.sorted(by: { $0.key < $1.key }), id: \.key) { (currency, net) in
                    HStack {
                        Text(currency).foregroundStyle(Theme.Text.secondary)
                        Spacer()
                        Text(formatCurrency(net, currency: currency))
                            .font(.callout.bold())
                            .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                    }
                }
            } header: {
                Text("Mi saldo")
            }
        }

        Section {
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                LabeledContent("Liquidaciones abiertas", value: "\(d.moneyPreview.openSettlements)")
            }
        }

        Section {
            if d.obligationsPreview.isEmpty {
                Label("Sin obligaciones pendientes", systemImage: "doc.text.below.ecg")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(d.obligationsPreview) { o in
                    NavigationLink {
                        ObligationDetailView(obligationId: o.obligationId, context: context, container: container)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.Text.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.kind ?? "Obligación").font(.callout).foregroundStyle(Theme.Text.primary)
                                if let s = o.status {
                                    Text(s).font(.caption).foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                            Spacer()
                            if let amount = o.amount, let cur = o.currency {
                                Text("\(Int(amount)) \(cur)")
                                    .font(.callout.bold())
                                    .foregroundStyle(Theme.Text.primary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Obligaciones recientes")
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let actions = store.descriptor?.actions, !actions.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                quickActionsMenu(actions: actions)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Fallback") {
                    Button {
                        isShowingClassicSheet = true
                    } label: {
                        Label("Vista clásica", systemImage: "rectangle.stack")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Más opciones")
        }
    }

    @ViewBuilder
    private func quickActionsMenu(actions: [AvailableAction]) -> some View {
        Menu {
            ForEach(actions) { action in
                let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
                Button {
                    quickActionsRouter.open(ActionRouter.destination(for: action, in: .context(context.id)))
                } label: {
                    Label(action.label, systemImage: presentation.symbolName)
                }
                .disabled(!action.enabled)
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
        .accessibilityLabel("Acciones del contexto")
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
