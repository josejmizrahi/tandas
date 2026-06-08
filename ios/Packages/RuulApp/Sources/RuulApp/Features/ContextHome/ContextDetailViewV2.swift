import SwiftUI
import RuulCore

/// R.5A.F.3 — ContextDetailView v2 backed by `context_detail_descriptor`.
///
/// Tabs Overview / People / Resources / Money / More. Cada tab se hace
/// visible sólo si la sección correspondiente está en `descriptor.sections`
/// (que ya viene filtrada por `my_permissions` desde B.7).
///
/// Mantener `ContextHomeView` (legacy) hasta paridad con 8 founder-canon
/// actor_subtypes (family/company/trip/project/community/trust/generic/friend_group).
public struct ContextDetailViewV2: View {
    let contextId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ContextDescriptorStore
    @State private var hierarchyStore: ContextHierarchyStore
    @State private var selectedTab: Tab = .overview
    /// R.5A cutover — fallback a `ContextHomeView` legacy cuando V2 aún no
    /// cubre algún flow (create_*, edit_context, governance wizards…).
    @State private var isShowingClassicSheet = false
    /// R.5A wire — Quick Actions del context_available_actions canónico.
    @State private var quickActionsRouter = NoopActionRouter()
    @State private var pushedActionDestination: QuickActionPush?
    @State private var isShowingCreateChild = false
    /// R.5A wire — attention_inbox filtrado por este contexto (F.NAV.10).
    @State private var presentedAttention: AttentionDestination?
    @State private var isShowingAllAttention = false
    /// R.5B.5c — lista de conflicts del contexto (carga lazy cuando descriptor.conflicts.openCount>0).
    @State private var conflictsList: ContextConflictList = .empty
    @State private var didLoadConflictsForContext: UUID?
    @State private var pendingContextConflict: ContextConflictItem?
    @State private var isShowingContextConflictDialog = false
    @State private var contextConflictAlert: ContextConflictsAlert?
    @State private var isShowingContextConflictAlert = false
    @State private var isResolvingContextConflict = false

    /// Mismo enum que ContextHomeView v1 para reusar el patrón de destinations.
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

    /// Categorías de tabs founder spec §11. "More" agrupa governance/documents/
    /// activity/settings — F.4 las expandirá como sub-tabs.
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
        /// Sections del descriptor que pertenecen a esta tab.
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
        // R.2U.3 — breadcrumb sticky arriba (sólo subcontextos con ancestros).
        .safeAreaInset(edge: .top, spacing: 0) {
            if !context.isPersonal && !hierarchyStore.ancestors.isEmpty {
                BreadcrumbView(
                    context: context,
                    ancestors: hierarchyStore.ancestors,
                    contextStore: container.contextStore
                )
            }
        }
        // F.2X.2 — router
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
        // Attention sheets (R.5Y.A2 — dispatcher único)
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
        // R.5B.5c — dialog + alert de conflicts aislados en ViewModifier para
        // evitar type-checker timeout del body (ya tenía 13+ modifiers).
        .modifier(ContextConflictsModifier(
            pendingConflict: $pendingContextConflict,
            isShowingDialog: $isShowingContextConflictDialog,
            alert: $contextConflictAlert,
            isShowingAlert: $isShowingContextConflictAlert,
            dialogMessage: contextConflictDialogMessage(_:),
            onKind: { item, kind in resolveContextConflict(item, kind: kind) }
        ))
    }

    @ViewBuilder
    private func descriptorContent(_ d: ContextDetailDescriptor) -> some View {
        let availableTabs = Tab.allCases.filter { tab in
            tab.sectionKeys.contains { sectionKey in
                d.sections.contains { $0.sectionKey == sectionKey && $0.visible }
            }
        }
        VStack(spacing: Theme.Spacing.md) {
            if availableTabs.count > 1 {
                Picker("Vista", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
            }
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    tabContent(d, tab: effectiveTab(availableTabs))
                    Spacer(minLength: Theme.Spacing.xl)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.sm)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            if !availableTabs.contains(selectedTab), let first = availableTabs.first {
                selectedTab = first
            }
        }
    }

    private func effectiveTab(_ available: [Tab]) -> Tab {
        available.contains(selectedTab) ? selectedTab : (available.first ?? .overview)
    }

    // MARK: - Tab content router

    @ViewBuilder
    private func tabContent(_ d: ContextDetailDescriptor, tab: Tab) -> some View {
        switch tab {
        case .overview:  overviewTab(d)
        case .people:    peopleTab(d)
        case .resources: resourcesTab(d)
        case .money:     moneyTab(d)
        case .more:      moreTab(d)
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private func overviewTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            attentionCard
            if d.conflicts.hasOpenConflicts {
                conflictsCard(summary: d.conflicts, list: conflictsList)
            }
            metricsCard(d.metrics)
            if !d.widgets.isEmpty { widgetsRow(d.widgets) }
            childContextsFromDescriptor(d.childContextsPreview)
            if !d.activityPreview.isEmpty {
                activityCard(d.activityPreview)
            }
        }
    }

    // MARK: - Child contexts via descriptor (B.7.1)

    @ViewBuilder
    private func childContextsFromDescriptor(_ children: [ContextChildPreview]) -> some View {
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Espacios dentro de \(context.displayName)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(children) { child in
                            childDescriptorCard(child)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: childSymbolName(child))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.badgeFill, in: Circle())
            Spacer(minLength: 0)
            Text(child.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(childSubtypeLabel(child.actorSubtype ?? "generic"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 140, height: 140, alignment: .topLeading)
        .padding(Theme.Spacing.md)
        .background(Theme.Surface.card, in: Theme.cardShape())
        .overlay(
            Theme.cardShape()
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 0.5)
        )
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

    // MARK: - Child contexts (F.CONTEXT.4 — "Espacios dentro de X")

    @ViewBuilder
    private var childContextsCarousel: some View {
        if hierarchyStore.phase.isLoaded {
            let children = hierarchyStore.children
            if !children.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Espacios dentro de \(context.displayName)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.sm) {
                            ForEach(children) { child in
                                childCard(child)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func childCard(_ child: ContextHierarchyNode) -> some View {
        if let target = container.contextStore.availableContexts.first(where: { $0.id == child.id }) {
            NavigationLink(value: target) {
                childCardLabel(child)
            }
            .buttonStyle(.plain)
        } else {
            childCardLabel(child).opacity(0.5)
        }
    }

    @ViewBuilder
    private func childCardLabel(_ child: ContextHierarchyNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: child.appContext.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.badgeFill, in: Circle())
            Spacer(minLength: 0)
            Text(child.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(childSubtypeLabel(child.actorSubtype))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 140, height: 140, alignment: .topLeading)
        .padding(Theme.Spacing.md)
        .background(Theme.Surface.card, in: Theme.cardShape())
        .overlay(
            Theme.cardShape()
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 0.5)
        )
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

    // MARK: - Attention (F.NAV.10 — surface inbox filtrado por contexto)

    private var contextAttentionItems: [AttentionItem] {
        container.attentionInboxStore.items.filter { $0.contextActorId == context.id }
    }

    @ViewBuilder
    private var attentionCard: some View {
        let items = contextAttentionItems
        if items.isEmpty {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atención")
                        .font(.subheadline.weight(.semibold))
                    Text("Todo está al día")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Surface.card, in: Theme.cardShape())
        } else {
            Button {
                if items.count == 1 {
                    presentedAttention = AttentionDispatcher.destination(for: items[0])
                } else {
                    isShowingAllAttention = true
                }
            } label: {
                VStack(spacing: 0) {
                    HStack {
                        Label("Requiere atención", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(items.count == 1 ? "Ver" : "Ver \(items.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)

                    Divider().padding(.leading, Theme.Spacing.lg)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items.prefix(3)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: AttentionPresentation.symbol(for: item.kind))
                                    .font(.callout)
                                    .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 3) {
                                        Text(AttentionPresentation.ctaLabel(for: item.kind))
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.bold))
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        if items.count > 3 {
                            Text("+ \(items.count - 3) más")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 32)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            .buttonStyle(.plain)
        }
    }

    // R.5Y.A2 — handleAttentionTap / attentionDestination / attentionSymbol /
    // attentionTint / attentionCTALabel se eliminaron. Su trabajo lo hace
    // AttentionDispatcher + AttentionPresentation + AttentionDestinationSheet
    // (Components/AttentionDispatcher.swift).

    @ViewBuilder
    private func metricsCard(_ m: ContextMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.lg) {
                metricItem(value: "\(m.memberCount)", label: "Miembros", icon: "person.2.fill")
                Divider().frame(height: 36)
                metricItem(value: "\(m.pendingDecisions)", label: "Decisiones", icon: "questionmark.circle.fill")
                Divider().frame(height: 36)
                metricItem(value: "\(m.openObligations)", label: "Obligaciones", icon: "doc.text.below.ecg.fill")
            }
            if !m.resourceCountByClass.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(m.resourceCountByClass.sorted(by: { $0.value > $1.value }), id: \.key) { (key, count) in
                            chipBadge("\(count) \(key.replacingOccurrences(of: "_", with: " "))", tint: .blue)
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    @ViewBuilder
    private func metricItem(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.bold())
        }
    }

    @ViewBuilder
    private func widgetsRow(_ widgets: [ContextWidget]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Dashboard")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(widgets) { widget in
                        contextWidgetCard(widget)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextWidgetCard(_ widget: ContextWidget) -> some View {
        if let _ = contextWidgetDestinationKey(widget.widgetKey) {
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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .font(.system(size: Theme.IconSize.md))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(widget.displayName)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            if let src = widget.dataSourceKey {
                Text(src).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(width: 140, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Surface.card, in: Theme.cardShape())
        .contentShape(Rectangle())
    }

    private func contextWidgetDestinationKey(_ key: String) -> String? {
        switch key {
        case "cash_balance", "budget_progress", "open_obligations":
            return "money"
        case "critical_resources":
            return "resources"
        case "member_count_summary":
            return "members"
        case "next_event":
            return "events"
        case "open_decisions":
            return "decisions"
        case "recent_activity":
            return "activity"
        case "settlement_status":
            return "settlement"
        case "upcoming_reservations":
            return "reservations"
        default:
            return nil
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

    @ViewBuilder
    private func activityCard(_ events: [ActivityPreviewEvent]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Actividad reciente").font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    Text("Ver todo").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            VStack(spacing: 0) {
                let take = Array(events.prefix(5))
                ForEach(take.enumerated().map { ($0, $1) }, id: \.1.id) { idx, ev in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: "bolt.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: Theme.IconSize.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                                .font(.subheadline)
                            if let when = ev.occurredAt {
                                Text(when.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.md)
                    if idx < take.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    // MARK: - People

    @ViewBuilder
    private func peopleTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("\(d.metrics.memberCount) miembros").font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                NavigationLink {
                    MembersListView(context: context, container: container)
                } label: {
                    Text("Ver todos").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            if d.membersPreview.isEmpty {
                EmptyCard(icon: "person.2", label: "Sin miembros para mostrar")
            } else {
                VStack(spacing: 0) {
                    ForEach(d.membersPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, m in
                        NavigationLink {
                            MembersListView(context: context, container: container)
                        } label: {
                            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                                Circle()
                                    .fill(Color.accentColor.badgeFillSubtle)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Text(m.displayName.first.map { String($0) } ?? "?")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(Color.accentColor)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.displayName).font(.body).foregroundStyle(.primary)
                                    Text(m.membershipType).font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < d.membersPreview.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            if !d.roles.isEmpty {
                Text("Roles").font(.subheadline.bold()).foregroundStyle(.secondary).padding(.top, Theme.Spacing.md)
                VStack(spacing: 0) {
                    ForEach(d.roles.enumerated().map { ($0, $1) }, id: \.1.id) { idx, role in
                        NavigationLink {
                            MembersListView(context: context, container: container)
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key")
                                    .foregroundStyle(.secondary)
                                    .frame(width: Theme.IconSize.sm)
                                Text(role.displayName).font(.body).foregroundStyle(.primary)
                                Spacer()
                                Text("\(role.memberCount)").font(.caption).foregroundStyle(.tertiary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < d.roles.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    // MARK: - Resources

    @ViewBuilder
    private func resourcesTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("\(d.resourcesPreview.count) recursos · \(d.metrics.resourceCountByClass.values.reduce(0, +)) en total")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            if d.resourcesPreview.isEmpty {
                EmptyCard(icon: "cube", label: "Sin recursos en este contexto")
            } else {
                let byClass = Dictionary(grouping: d.resourcesPreview) { $0.classKey ?? "generic" }
                ForEach(byClass.keys.sorted(), id: \.self) { classKey in
                    if let items = byClass[classKey] {
                        Text(classKey.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        VStack(spacing: 0) {
                            ForEach(items.enumerated().map { ($0, $1) }, id: \.1.id) { idx, r in
                                NavigationLink {
                                    ResourceDetailViewV2(resourceId: r.resourceId, context: context, container: container)
                                } label: {
                                    HStack(alignment: .center, spacing: Theme.Spacing.md) {
                                        Image(systemName: "cube")
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: Theme.IconSize.sm)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.displayName).font(.body).foregroundStyle(.primary)
                                            if let sub = r.subtypeKey {
                                                Text(sub.replacingOccurrences(of: "_", with: " "))
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, Theme.Spacing.md)
                                    .padding(.vertical, Theme.Spacing.md)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if idx < items.count - 1 { Divider().padding(.leading, 56) }
                            }
                        }
                        .background(Theme.Surface.card, in: Theme.cardShape())
                    }
                }
            }
        }
    }

    // MARK: - Money

    @ViewBuilder
    private func moneyTab(_ d: ContextDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            myBalanceCard(d.moneyPreview.myBalanceByCurrency)
            NavigationLink {
                SettlementView(context: context, container: container)
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Liquidaciones abiertas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(d.moneyPreview.openSettlements)")
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.lg)
                .background(Theme.Surface.card, in: Theme.cardShape())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if d.obligationsPreview.isEmpty {
                EmptyCard(icon: "doc.text.below.ecg", label: "Sin obligaciones pendientes")
            } else {
                Text("Obligaciones recientes")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(d.obligationsPreview.enumerated().map { ($0, $1) }, id: \.1.id) { idx, o in
                        NavigationLink {
                            ObligationDetailView(obligationId: o.obligationId, context: context, container: container)
                        } label: {
                            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                    .frame(width: Theme.IconSize.sm)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.kind ?? "Obligación").font(.body).foregroundStyle(.primary)
                                    if let s = o.status {
                                        Text(s).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let amount = o.amount, let cur = o.currency {
                                    Text("\(Int(amount)) \(cur)").font(.subheadline.bold()).foregroundStyle(.primary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < d.obligationsPreview.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    // MARK: - My balance (B.7.1)

    @ViewBuilder
    private func myBalanceCard(_ balances: [String: Double]) -> some View {
        if !balances.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Mi saldo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let sorted = balances.sorted { $0.key < $1.key }
                ForEach(sorted, id: \.key) { (currency, net) in
                    HStack {
                        Text(currency)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatCurrency(net, currency: currency))
                            .font(.title3.bold())
                            .foregroundStyle(net >= 0 ? .green : .red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    private func formatCurrency(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(Int(value)) \(currency)"
    }

    // MARK: - Pending invitations (B.7.1)

    @ViewBuilder
    private func pendingInvitationsCard(_ invites: [ContextInvitePreview]) -> some View {
        if !invites.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Invitaciones activas (\(invites.count))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(invites.enumerated().map { ($0, $1) }, id: \.1.id) { idx, inv in
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(.blue)
                                .frame(width: Theme.IconSize.sm)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inv.code)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(inviteUsageLabel(inv))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let exp = inv.expiresAt {
                                Text(exp.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.md)
                        if idx < invites.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    private func inviteUsageLabel(_ inv: ContextInvitePreview) -> String {
        if let max = inv.maxUses {
            return "\(inv.usedCount) / \(max) usos"
        }
        return "\(inv.usedCount) usos · ilimitado"
    }

    // MARK: - More (flat sections list — F.3 estilo)

    @ViewBuilder
    private func moreTab(_ d: ContextDetailDescriptor) -> some View {
        let moreSections = d.sections.filter {
            $0.visible && Tab.more.sectionKeys.contains($0.sectionKey)
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            pendingInvitationsCard(d.pendingInvitationsPreview)
            if moreSections.isEmpty {
                EmptyCard(icon: "ellipsis.circle", label: "Sin más secciones")
            } else {
                Text("Secciones adicionales")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(moreSections.enumerated().map { ($0, $1) }, id: \.1.id) { idx, section in
                        NavigationLink {
                            moreSectionDestination(section.sectionKey)
                        } label: {
                            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                                Image(systemName: section.icon ?? "circle")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: Theme.IconSize.sm)
                                Text(section.displayName).font(.body).foregroundStyle(.primary)
                                Spacer()
                                if let perm = section.requiredPermission {
                                    Text(perm).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < moreSections.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            if !d.permissions.isEmpty {
                Text("Mis permisos (\(d.permissions.count))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, Theme.Spacing.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(d.permissions, id: \.self) { p in
                            chipBadge(p, tint: .purple)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar (extracted para ayudar al type-checker)

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

    // MARK: - Quick Actions

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

    /// Mismo dispatch que ContextHomeView v1 — mapea action_key → destination.
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

    // MARK: - Helpers

    /// R.5A wire — destinos legacy por section_key del More tab. Fallback a
    /// ActivityFeed si la section no tiene un destino dedicado.
    @ViewBuilder
    private func moreSectionDestination(_ sectionKey: String) -> some View {
        switch sectionKey {
        case "calendar":   EventsListView(context: context, container: container)
        case "governance": DecisionsListView(context: context, container: container)
        case "documents":  ActivityFeedView(context: context, container: container)  // sin lista dedicada todavía
        case "activity":   ActivityFeedView(context: context, container: container)
        case "settings":   ContextSettingsView(context: context, container: container)
        default:           ActivityFeedView(context: context, container: container)
        }
    }

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(tint.badgeFillSubtle, in: Capsule())
    }

    // MARK: - R.5B.5c — Conflicts card + load + resolve

    @ViewBuilder
    func conflictsCard(summary: ContextConflictsSummary, list: ContextConflictList) -> some View {
        let open = summary.openCount
        let critical = summary.criticalCount
        let tint: Color = critical > 0 ? .red : .orange
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Theme.IconSize.md, weight: .regular))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conflictos abiertos")
                        .font(.subheadline.bold())
                    Text(conflictsSubtitle(open: open, critical: critical))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(open)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(tint)
            }
            VStack(spacing: Theme.Spacing.xs) {
                ForEach(list.items.prefix(4)) { item in
                    conflictRowLink(item)
                }
            }
            if list.items.count > 4 || list.items.count < open {
                NavigationLink {
                    ContextConflictsListView(contextActorId: contextId, context: context, container: container)
                } label: {
                    HStack {
                        Text(list.items.count < open ? "Ver \(open) conflictos" : "Ver todos (\(open))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.card))
        .overlay(
            Theme.cardShape(Theme.Radius.card)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func conflictRowLink(_ item: ContextConflictItem) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                ResourceDetailViewV2(resourceId: item.resourceId, context: context, container: container)
            } label: {
                contextConflictRow(item)
            }
            .buttonStyle(.plain)
            Button {
                guard !isResolvingContextConflict else { return }
                pendingContextConflict = item
                isShowingContextConflictDialog = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: Theme.IconSize.sm))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .disabled(isResolvingContextConflict)
        }
        .background(contextConflictSeverityTint(item.severity).badgeFillSubtle, in: Theme.cardShape())
    }

    @ViewBuilder
    private func contextConflictRow(_ item: ContextConflictItem) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Image(systemName: contextConflictSeverityIcon(item.severity))
                .font(.system(size: Theme.IconSize.sm))
                .foregroundStyle(contextConflictSeverityTint(item.severity))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.conflictTypeDisplay ?? item.conflictType)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.resourceDisplayName ?? "Recurso")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.leading, Theme.Spacing.sm)
        .contentShape(Rectangle())
    }

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
        case "critical": return Color.red
        case "warning":  return Color.orange
        case "info":     return Color.blue
        default:         return Color.secondary
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
                // El descriptor.conflicts counts cambian → reload del descriptor entero
                // para mantener el card oculto cuando openCount = 0.
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
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
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

/// Alert post-resolve fileprivate para ser accesible desde el ViewModifier.
fileprivate struct ContextConflictsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Aísla confirmation dialog + alert de conflictos fuera del body — preempt
/// type-checker timeout porque el body ya tenía 13+ modifiers.
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

// MARK: - EmptyCard helper

private struct EmptyCard: View {
    let icon: String
    let label: String
    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: Theme.IconSize.lg))
                .foregroundStyle(.tertiary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .background(Theme.Surface.card, in: Theme.cardShape())
    }
}
