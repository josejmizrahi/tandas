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
    /// R.5Z.fix.6 (founder feedback 2026-06-09) — Money tab CTAs primarias.
    @State private var isShowingRecordExpense = false
    @State private var isShowingCreateObligation = false

    enum QuickActionPush: Hashable, Identifiable {
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
        // R.5Z.fix.CONTEXT.TABS (founder 2026-06-10) — tabs nuevos events +
        // governance para que un grupo de amigos pueda organizarse y convivir
        // end-to-end sin esconder eventos/decisiones en "Más".
        case overview, events, people, resources, money, governance, more
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview:   return "Resumen"
            case .events:     return "Eventos"
            case .people:     return "Personas"
            case .resources:  return "Recursos"
            case .money:      return "Dinero"
            case .governance: return "Gobierno"
            case .more:       return "Más"
            }
        }
        var sectionKeys: Set<String> {
            switch self {
            case .overview:   return ["overview"]
            case .events:     return ["calendar"]
            case .people:     return ["people"]
            case .resources:  return ["resources"]
            case .money:      return ["money", "obligations"]
            case .governance: return ["governance"]
            case .more:       return ["documents", "activity", "settings"]
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
                ContextDetailV2PersonalSpace(
                    context: context,
                    container: container,
                    attentionItems: contextAttentionItems,
                    presentedAttention: $presentedAttention,
                    isShowingAllAttention: $isShowingAllAttention
                )
            } else {
                switch store.phase {
                case .idle, .loading:
                    RuulLoadingState()
                case .failed(let message):
                    RuulErrorState(message: message) {
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
        .toolbar {
            ContextDetailV2Toolbar(
                context: context,
                actions: store.descriptor?.actions,
                quickActionsRouter: quickActionsRouter,
                pushedActionDestination: $pushedActionDestination,
                isShowingSettings: $isShowingSettings
            )
        }
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
        // R.5Z.fix.6 — Money tab CTAs primarias (founder 2026-06-09).
        .sheet(isPresented: $isShowingRecordExpense, onDismiss: {
            Task { await store.load(contextId: contextId) }
        }) {
            NavigationStack {
                RecordExpenseView(
                    context: context,
                    store: MoneyStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId),
                    container: container
                )
            }
        }
        .sheet(isPresented: $isShowingCreateObligation, onDismiss: {
            Task { await store.load(contextId: contextId) }
        }) {
            CreateObligationView(context: context, container: container)
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
                    // Issue 3 founder (audit 2026-06-14) — 7 tabs en
                    // `Picker.segmented` se encimaban en iPhone (no caben).
                    // Cambio a `ScrollView horizontal` con chips estilo Apple
                    // Stocks/Music/Calendar: cada tab es un botón compacto,
                    // el seleccionado tiene tint + background prominente. El
                    // usuario puede scrollear suavemente y ver todos.
                    tabBar(availableTabs)
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

    /// Issue 3 founder — tab bar horizontal scrolleable. Resuelve el
    /// "encimado" del segmented picker cuando hay >4 tabs.
    @ViewBuilder
    private func tabBar(_ tabs: [Tab]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        tabChip(tab)
                            .id(tab)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selectedTab) { _, newTab in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newTab, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func tabChip(_ tab: Tab) -> some View {
        let isSelected = effectiveTabIs(tab)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Theme.Text.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.badgeFillSubtle : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18),
                            lineWidth: 0.8
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func effectiveTabIs(_ tab: Tab) -> Bool {
        let avail = Tab.allCases.filter { _ in true }
        let effective = avail.contains(selectedTab) ? selectedTab : (avail.first ?? .overview)
        return effective == tab
    }

    // MARK: - Tab dispatch

    @ViewBuilder
    private func tabSections(_ d: ContextDetailDescriptor, tab: Tab) -> some View {
        switch tab {
        case .overview:
            overviewSections(d)
        case .events:
            ContextDetailV2EventsTab(
                descriptor: d,
                context: context,
                container: container,
                pushedActionDestination: $pushedActionDestination
            )
        case .people:
            ContextDetailV2PeopleTab(descriptor: d, context: context, container: container)
        case .resources:
            ContextDetailV2ResourcesTab(descriptor: d, context: context, container: container)
        case .money:
            ContextDetailV2MoneyTab(
                descriptor: d,
                context: context,
                container: container,
                isShowingRecordExpense: $isShowingRecordExpense,
                isShowingCreateObligation: $isShowingCreateObligation
            )
        case .governance:
            ContextDetailV2GovernanceTab(
                descriptor: d,
                context: context,
                container: container,
                pushedActionDestination: $pushedActionDestination
            )
        case .more:
            ContextDetailV2MoreTab(
                descriptor: d,
                moreSectionKeys: Tab.more.sectionKeys,
                context: context,
                container: container
            )
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
        ContextDetailV2HeroSection(context: context, descriptor: d)
        ContextDetailV2AttentionSection(
            items: contextAttentionItems,
            presentedAttention: $presentedAttention,
            isShowingAllAttention: $isShowingAllAttention
        )
        if d.conflicts.hasOpenConflicts {
            ContextDetailV2ConflictsSection(
                summary: d.conflicts,
                list: conflictsList,
                contextId: contextId,
                context: context,
                container: container,
                isResolvingContextConflict: isResolvingContextConflict,
                pendingContextConflict: $pendingContextConflict,
                isShowingContextConflictDialog: $isShowingContextConflictDialog
            )
        }
        let filteredWidgets = overviewDashboardWidgets(d.widgets, descriptor: d)
        if !filteredWidgets.isEmpty {
            ContextDetailV2DashboardSection(
                widgets: filteredWidgets,
                descriptor: d,
                context: context,
                container: container
            )
        }
        if hasNextEventWidget(d.widgets) {
            ContextDetailV2NextEventSection(context: context, container: container)
        }
        if !d.moneyPreview.myBalanceByCurrency.isEmpty {
            ContextDetailV2BalanceSection(money: d.moneyPreview, context: context, container: container)
        }
        if !d.childContextsPreview.isEmpty {
            ContextDetailV2ChildrenSection(children: d.childContextsPreview, context: context, container: container)
        }
        if !d.activityPreview.isEmpty {
            ContextDetailV2ActivitySection(events: d.activityPreview, context: context, container: container)
        }
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

    // MARK: - Quick actions routing (F.2X)

    private func handleQuickAction(_ destination: ActionDestination) {
        // F.2X — el mapeo key→destino vive en ActionRouter; aquí sólo se
        // decide la navegación local (push de tab / sheet).
        switch ActionRouter.quickActionDestination(for: destination.actionKey) {
        case .createResource:     pushedActionDestination = .resources
        case .createEvent:        pushedActionDestination = .events
        case .createDecision:     pushedActionDestination = .decisions
        case .recordExpense:      pushedActionDestination = .money
        case .inviteMember:       pushedActionDestination = .members
        case .createRule:         pushedActionDestination = .rules
        case .createChildContext: isShowingCreateChild = true
        default: break
        }
    }

    // MARK: - R.5B.5c — Conflict helpers (preservados intactos)

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

// MARK: - Previews

#Preview("Contexto — Cena Semanal") {
    NavigationStack {
        ContextDetailViewV2(
            contextId: MockRuulRPCClient.DemoIds.cenaSemanal,
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
