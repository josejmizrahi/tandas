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
    // Fase 9.6 — `selectedTab` y `enum Tab` eliminados: la nueva doctrina
    // es una sola lista scrollable con todos los dominios visibles. Drill-
    // down con "Ver todos" en cada section.
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

    // Fase 9.6 — enum Tab eliminado. Doctrina: una sola lista scrollable
    // con todos los dominios. Drill-down via NavigationLink "Ver todos" en
    // cada section. Cero estado de tab, cero switcher, cero ambigüedad.

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
        // Fase 9.5 (founder feedback iter 4) — el ToolbarItem(.principal) con
        // VStack 2 líneas seguía siendo truncado por iOS. Vuelvo a
        // `navigationTitle` plano + Menu picker prominente en safeAreaInset.
        // Llena el gap entre nav y contenido con info útil (current tab).
        .navigationTitle(context.isPersonal ? "Mi espacio" : (store.descriptor?.contextDisplayName ?? context.displayName))
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
        // R.10.E.2 D1 (founder firmado 2026-06-14) — sheets de RecordExpense/
        // CreateObligation eliminadas del cuerpo del ContextDetail.
        // Acceso vía toolbar `+` → descriptor.actions section "money",
        // navega a MoneyHomeView donde se abren los flujos.
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

    /// Fase 9.6 (founder feedback 2026-06-14, iter 5) — tras 5 intentos de
    /// hacer que el switcher de tabs se vea bien (segmented → ScrollView
    /// horizontal → Menu en toolbar → Menu pill prominente), founder pidió
    /// "una mejor forma que no sea con switcher".
    ///
    /// Doctrina: **eliminar tabs**. Mostrar TODO el contenido en una sola
    /// lista scrollable estilo Apple Music home / Apple Wallet / Settings.
    /// Cada dominio (Personas / Recursos / Dinero / Gobierno) tiene su
    /// preview compacto + "Ver todos" para drill-down. Cero estado, cero
    /// switcher, cero ambigüedad.
    @ViewBuilder
    private func descriptorContent(_ d: ContextDetailDescriptor) -> some View {
        let visibleKeys = Set(d.sections.filter { $0.visible }.map(\.sectionKey))
        List {
            unifiedSections(d, visibleKeys: visibleKeys)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Solo breadcrumb (cuando hay ancestros). Sin tab picker.
            if !context.isPersonal && !hierarchyStore.ancestors.isEmpty {
                BreadcrumbView(
                    context: context,
                    ancestors: hierarchyStore.ancestors,
                    contextStore: container.contextStore
                )
                .background(.bar)
            }
        }
    }

    /// Fase 9.6 — todas las sections del descriptor renderizadas en una sola
    /// lista. Orden por importancia: Hero compacto → Atención → Conflictos →
    /// Resumen rápido → Personas → Recursos → Eventos → Dinero → Gobierno →
    /// Subespacios → Actividad → Más (settings + documents).
    @ViewBuilder
    private func unifiedSections(_ d: ContextDetailDescriptor, visibleKeys: Set<String>) -> some View {
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
        // R.10.E.5 (founder firmado 2026-06-15) — Eventos siempre visible
        // para contextos colectivos: cuando hay preview muestra rows + header
        // "Ver todos"; cuando está vacío muestra empty CTA "Crear el primer
        // evento" (Camino B firmado).
        ContextDetailV2EventsSection(descriptor: d, context: context, container: container)
        // Personas, recursos, gobernanza — cada uno con su preview + "Ver todos".
        if visibleKeys.contains("people") {
            ContextDetailV2PeopleTab(descriptor: d, context: context, container: container)
        }
        // R.10.E.6 (founder firmado 2026-06-15) — Recursos siempre visible
        // para contextos colectivos (founder: "EN CONTEXT DETAIL ESA FALTA
        // ESA SECCION"). Antes estaba gateado por
        // `visibleKeys.contains("resources")` lo que la ocultaba en algunos
        // contextos. Posición: entre Miembros y Dinero — flujo natural
        // "quién está · qué compartimos · cuánto debemos · cómo decidimos".
        ContextDetailV2ResourcesSection(descriptor: d, context: context, container: container)
        // Money inline (balance + obligaciones + settlements). Después de
        // Recursos: lo que tenemos → lo que debemos.
        if visibleKeys.contains("money") || visibleKeys.contains("obligations") {
            ContextDetailV2MoneyTab(
                descriptor: d,
                context: context,
                container: container
            )
        }
        // R.10.E.5 — Gobierno separado en 2 Sections por data type (decisiones
        // explícitas vs reglas automáticas). Apple HIG: una Section = un tipo.
        // Posición: después de Dinero — cómo decidimos cosas, incluyendo $.
        if visibleKeys.contains("governance") {
            ContextDetailV2DecisionsSection(descriptor: d, context: context, container: container)
            ContextDetailV2RulesSection(context: context, container: container)
        }
        // Subespacios.
        if !d.childContextsPreview.isEmpty {
            ContextDetailV2ChildrenSection(children: d.childContextsPreview, context: context, container: container)
        }
        // Actividad reciente.
        if !d.activityPreview.isEmpty {
            ContextDetailV2ActivitySection(events: d.activityPreview, context: context, container: container)
        }
        // Más: documents + settings + activity link (consolidado).
        ContextDetailV2MoreTab(
            descriptor: d,
            moreSectionKeys: ["documents", "activity", "settings"],
            context: context,
            container: container
        )
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

    // Fase 9.7 — overviewSections(_:) eliminada: era código muerto desde
    // 9.6. `unifiedSections(_:visibleKeys:)` la reemplazó con renderizado
    // secuencial de todos los dominios.

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
