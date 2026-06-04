import SwiftUI
import RuulCore

/// F.CONTEXT.1 — Context Home como dashboard operativo, no contenedor de
/// primitivas. Estilo Apple Home / Wallet / Fitness: ScrollView + cards.
///
/// Orden obligatorio (founder lock 2026-06-04):
///   1. Hero            — quién es este contexto + resumen ejecutivo
///   2. Atención        — items de attention_inbox filtrados por contexto
///   3. Qué quieres hacer — context_available_actions() grid 2×2/2×3
///   4. Resumen         — 4 mini-stats (miembros / recursos / eventos / decisiones)
///   5. Actividad       — feed friendly (sin keys técnicos)
///   6. Recursos        — título adaptado al subtype (Patrimonio / Activos / …)
///   7. Miembros        — top 5 + ver todos
///   8. Eventos         — próximos
///   9. Decisiones      — abiertas
///  10. Dinero          — balance personal + cuentas abiertas
///   + soportes (subcontextos, posibles relacionados, compromisos, reglas)
///   + sección "Lo que me importa" SOLO en contexto personal
public struct ContextHomeView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ContextHomeStore
    @State private var actionObligations: [Obligation] = []
    @State private var selectedObligationId: UUID?
    @State private var isShowingCreateObligation = false
    @State private var hierarchyStore: ContextHierarchyStore
    @State private var isShowingCreateChild = false
    @State private var similarityStore: SimilarityStore

    // F.2X.2 — Quick Actions router + push destinations
    @State private var quickActionsRouter = NoopActionRouter()
    @State private var pushedActionDestination: QuickActionPush?

    // F.NAV.10 — atención filtrada por contexto
    @State private var presentedAttention: AttentionItem?
    @State private var isShowingAllAttention = false
    @State private var isShowingPendingInvitations = false

    private enum QuickActionPush: Hashable, Identifiable {
        case resources, events, decisions, money, members, rules
        var id: String { String(describing: self) }
    }

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ContextHomeStore(rpc: container.rpc))
        _hierarchyStore = State(initialValue: ContextHierarchyStore(rpc: container.rpc))
        _similarityStore = State(initialValue: SimilarityStore(rpc: container.rpc))
    }

    private var rpc: any RuulRPCClient { container.rpc }
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
                if let summary = store.summary {
                    dashboard(summary)
                }
            }
        }
        .navigationTitle(context.displayName)
        .toolbar {
            // F.CONTEXT.4 — "+" en la barra: única superficie de creación.
            // Las acciones vienen verbatim de context_available_actions().
            if !context.isPersonal {
                ToolbarItem(placement: .topBarTrailing) {
                    quickActionsToolbarMenu
                }
            }
        }
        // R.2U.3 — breadcrumb sticky arriba (sólo si hay ancestros).
        .safeAreaInset(edge: .top, spacing: 0) {
            if !context.isPersonal && !hierarchyStore.ancestors.isEmpty {
                BreadcrumbView(
                    context: context,
                    ancestors: hierarchyStore.ancestors,
                    contextStore: container.contextStore
                )
            }
        }
        .task(id: context.id) {
            // F.CONTEXT.4 fix — al navegar a un subcontexto vía push, sincroniza
            // contextStore + recents para que el switcher/Home reflejen el actual.
            container.contextStore.switchTo(context)
            await container.contextPreferencesStore.recordVisit(context.id)
            await store.load(context: context)
            await loadActionObligations()
            await container.attentionInboxStore.load()
            await container.invitationsStore.load(actorId: myActorId)
            if !context.isPersonal {
                await hierarchyStore.load(contextId: context.id)
                await similarityStore.load(contextId: context.id, myActorId: myActorId)
            }
        }
        .refreshable {
            await store.load(context: context)
            await loadActionObligations()
            await container.attentionInboxStore.load()
            await container.invitationsStore.load(actorId: myActorId)
            if !context.isPersonal {
                await hierarchyStore.load(contextId: context.id)
            }
            await container.contextStore.load()
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
            await loadActionObligations()
            await container.attentionInboxStore.load()
            if !context.isPersonal {
                await hierarchyStore.load(contextId: context.id)
            }
        }
        // Sheets
        .sheet(item: Binding(get: { selectedObligationId.map { ObligationIdWrapper(id: $0) } },
                              set: { selectedObligationId = $0?.id })) { wrapper in
            ObligationDetailView(obligationId: wrapper.id, context: context, container: container)
        }
        .sheet(isPresented: $isShowingCreateObligation, onDismiss: {
            Task { await loadActionObligations() }
        }) {
            CreateObligationView(context: context, container: container)
        }
        .sheet(isPresented: $isShowingCreateChild) {
            CreateChildContextSheet(parent: context, container: container) { newCtx in
                container.contextStore.switchTo(newCtx)
            }
        }
        .sheet(item: $presentedAttention) { item in
            attentionDestination(for: item)
        }
        .sheet(isPresented: $isShowingPendingInvitations) {
            PendingInvitationsView(container: container)
        }
        .sheet(isPresented: $isShowingAllAttention) {
            NavigationStack {
                AllContextAttentionView(items: attentionItemsForSheet) { item in
                    isShowingAllAttention = false
                    handleAttentionTap(item)
                }
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
    }

    // MARK: - Dashboard

    @ViewBuilder
    private func dashboard(_ summary: ContextSummary) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                heroCard(summary)

                if context.isPersonal {
                    personalTodayCard
                    if let world = store.world {
                        personalResourcesCard(world)
                        personalObligationsCard(world)
                    }
                } else {
                    // F.CONTEXT.4 — orden por prioridad del usuario, no por tipos:
                    //   atención → próximamente → actividad → espacios → recursos → dinero → miembros
                    attentionCard
                    upcomingCard(summary)
                    activityCard(summary)
                    childContextsCard
                    resourcesCard(summary)
                    moneyCard(summary)
                    membersCard(summary)

                    // Soportes — aparecen sólo si tienen contenido
                    similarContextsCard
                    actionObligationsCard
                    rulesCard(summary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
    }

    // MARK: - 1. Hero

    @ViewBuilder
    private func heroCard(_ summary: ContextSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: context.symbolName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(heroTitle(summary))
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text(contextTypeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !context.isPersonal {
                heroStatusLine(summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// F.CONTEXT.4 — Status line en lugar de stats estructurales. Muestra lo
    /// que importa: eventos próximos · decisiones pendientes · cuentas abiertas.
    /// Si todo es 0 → "Todo al día 🎉".
    @ViewBuilder
    private func heroStatusLine(_ summary: ContextSummary) -> some View {
        let upcoming = summary.upcomingEvents.count
        let pending = summary.pendingDecisions
        let open = summary.openObligationsCount
        let attention = contextAttentionItems.count
        let parts = heroStatusParts(upcoming: upcoming, pending: pending, open: open, attention: attention)

        if parts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Todo al día 🎉")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
        } else {
            Text(parts.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    /// Builders + `var` no conviven con `@ViewBuilder` — el array se compone
    /// en una función plana y la vista sólo lo renderiza.
    private func heroStatusParts(upcoming: Int, pending: Int, open: Int, attention: Int) -> [String] {
        var parts: [String] = []
        if upcoming > 0 {
            parts.append(upcoming == 1 ? "1 evento próximo" : "\(upcoming) eventos próximos")
        }
        if pending > 0 {
            parts.append(pending == 1 ? "1 decisión pendiente" : "\(pending) decisiones pendientes")
        }
        if open > 0 {
            parts.append(open == 1 ? "1 cuenta abierta" : "\(open) cuentas abiertas")
        }
        if parts.isEmpty && attention > 0 {
            parts.append(attention == 1 ? "1 pendiente" : "\(attention) pendientes")
        }
        return parts
    }

    private func heroTitle(_ summary: ContextSummary) -> String {
        context.isPersonal ? "Mi espacio" : summary.context.displayName
    }

    private var contextTypeLabel: String {
        if context.isPersonal { return "Lo que ves, administras y te deben" }
        switch context.subtype {
        case "family":       return "Familia"
        case "trip":         return "Viaje"
        case "community":    return "Comunidad"
        case "friend_group": return "Grupo"
        case "project":      return "Proyecto"
        case "company":      return "Empresa"
        case "trust":        return "Fideicomiso"
        default:             return context.kind == .legalEntity ? "Entidad" : "Contexto"
        }
    }

    // MARK: - 2. Atención

    private var contextAttentionItems: [AttentionItem] {
        container.attentionInboxStore.items.filter { $0.contextActorId == context.id }
    }

    /// Para el sheet "Pendientes": en contexto personal mostramos cross-context.
    private var attentionItemsForSheet: [AttentionItem] {
        context.isPersonal ? container.attentionInboxStore.items : contextAttentionItems
    }

    @ViewBuilder
    private var attentionCard: some View {
        let items = contextAttentionItems
        if items.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atención")
                        .font(.subheadline.weight(.semibold))
                    Text("Todo está al día 🎉")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.Surface.card, in: Theme.cardShape())
        } else {
            Button {
                if items.count == 1 {
                    handleAttentionTap(items[0])
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
                        Text(items.count == 1 ? "Ver →" : "Ver \(items.count) →")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider().padding(.leading, 16)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items.prefix(3)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: attentionSymbol(for: item.kind))
                                    .font(.callout)
                                    .foregroundStyle(attentionTint(for: item.kind))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(attentionCTALabel(for: item.kind))
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
                    .padding(16)
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
            .buttonStyle(.plain)
        }
    }

    private func attentionSymbol(for kind: String) -> String {
        switch kind {
        case "reservation_conflict": return "exclamationmark.triangle.fill"
        case "decision_vote":        return "hand.thumbsup.fill"
        case "obligation_pay":       return "creditcard.fill"
        case "obligation_complete":  return "checkmark.circle"
        case "invitation":           return "envelope.fill"
        default:                     return "circle.fill"
        }
    }

    private func attentionTint(for kind: String) -> Color {
        switch kind {
        case "reservation_conflict": return .red
        case "decision_vote":        return .purple
        case "obligation_pay",
             "obligation_complete":  return .green
        case "invitation":           return .blue
        default:                     return .secondary
        }
    }

    private func attentionCTALabel(for kind: String) -> String {
        switch kind {
        case "reservation_conflict": return "Resolver →"
        case "decision_vote":        return "Votar →"
        case "obligation_pay":       return "Pagar →"
        case "obligation_complete":  return "Marcar como hecho →"
        case "invitation":           return "Aceptar →"
        default:                     return "Ver →"
        }
    }

    private func handleAttentionTap(_ item: AttentionItem) {
        switch item.kind {
        case "invitation":
            isShowingPendingInvitations = true
        case "reservation_conflict":
            // El conflicto vive dentro del contexto — ya estamos aquí.
            // Push directo si quieres; por ahora abrimos All para que el usuario vea.
            isShowingAllAttention = true
        case "decision_vote", "obligation_pay", "obligation_complete":
            presentedAttention = item
        default:
            break
        }
    }

    @ViewBuilder
    private func attentionDestination(for item: AttentionItem) -> some View {
        NavigationStack {
            switch item.kind {
            case "decision_vote":
                DecisionDetailView(
                    decisionId: item.ctaScopeId,
                    context: context,
                    container: container
                )
            case "obligation_pay", "obligation_complete":
                ObligationDetailView(
                    obligationId: item.ctaScopeId,
                    context: context,
                    container: container
                )
            default:
                EmptyView()
            }
        }
    }

    // MARK: - 3. Toolbar Menu (Quick Actions — F.CONTEXT.4)

    /// F.CONTEXT.4 — Las acciones ya no son cards visibles, viven en un
    /// Menu "+" en la barra superior. Mismo `context_available_actions()`,
    /// mismo router; solo cambia la presentación.
    @ViewBuilder
    private var quickActionsToolbarMenu: some View {
        if let summary = store.summary, !summary.availableActions.isEmpty {
            Menu {
                ForEach(summary.availableActions) { action in
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

    // MARK: - 5. Actividad

    @ViewBuilder
    private func activityCard(_ summary: ContextSummary) -> some View {
        let items = Array(summary.recentActivity.prefix(5))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actividad reciente")
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    Text("Ver toda →")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                if items.isEmpty {
                    Text("Sin actividad todavía")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, activity in
                        activityRow(activity)
                        if idx < items.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: SummaryActivity) -> some View {
        // Proxy `ActivityEvent` para reusar `friendlyTitle` y `symbolName`.
        let proxy = ActivityEvent(
            id: UUID(),
            eventType: activity.eventType,
            actorId: activity.actorId,
            payload: activity.payload,
            occurredAt: activity.occurredAt
        )
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: proxy.symbolName)
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(proxy.friendlyTitle(currentActorId: myActorId))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let occurred = activity.occurredAt {
                    Text(occurred.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 6. Recursos destacados

    @ViewBuilder
    private func resourcesCard(_ summary: ContextSummary) -> some View {
        let resources = Array(summary.resources.prefix(10))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(resourcesCardTitle)
                    .font(.title3.weight(.semibold))
                Spacer()
                if summary.resourcesCount > resources.count {
                    NavigationLink {
                        ResourcesListView(context: context, container: container)
                    } label: {
                        Text("Ver todos →")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if resources.isEmpty {
                Text("Sin recursos todavía")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.Surface.card, in: Theme.cardShape())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(resources) { resource in
                            resourceCarouselCard(resource)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var resourcesCardTitle: String { "Recursos importantes" }

    @ViewBuilder
    private func resourceCarouselCard(_ resource: SummaryResource) -> some View {
        NavigationLink {
            ResourceDetailView(resourceId: resource.resourceId, context: context, container: container)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(Color.orange.badgeFill, in: Circle())
                Spacer(minLength: 0)
                Text(resource.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let value = resource.estimatedValue {
                    Text(value.currencyLabel(resource.currency))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 140, height: 140, alignment: .topLeading)
            .padding(Theme.Spacing.md)
            .background(Theme.Surface.card, in: Theme.cardShape())
            .overlay(
                Theme.cardShape()
                    .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 7. Miembros

    @ViewBuilder
    private func membersCard(_ summary: ContextSummary) -> some View {
        let count = summary.membersCount
        let visible = Array(summary.members.prefix(5))
        let extra = max(0, count - visible.count)
        NavigationLink {
            MembersListView(context: context, container: container)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Miembros")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(count == 1 ? "1 persona" : "\(count) personas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: -10) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, member in
                        ActorInitialsView(name: member.displayName, size: 32)
                            .overlay(
                                Circle().strokeBorder(Theme.Surface.card, lineWidth: 2)
                            )
                            .zIndex(Double(visible.count - idx))
                    }
                    if extra > 0 {
                        Text("+\(extra)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                            .overlay(
                                Circle().strokeBorder(Theme.Surface.card, lineWidth: 2)
                            )
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Próximamente (F.CONTEXT.4)

    /// Combina cronológicamente eventos próximos + decisiones abiertas +
    /// compromisos con due_at. La sección sólo aparece si tiene contenido.
    @ViewBuilder
    private func upcomingCard(_ summary: ContextSummary) -> some View {
        let items = upcomingItems(summary)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Próximamente")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        upcomingRowDestination(item)
                        if idx < items.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    private struct UpcomingItem: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let timeLabel: String
        let date: Date?
        let destination: UpcomingDestination
    }

    private enum UpcomingDestination {
        case event(UUID)
        case decision(UUID)
        case obligation(UUID)
    }

    private func upcomingItems(_ summary: ContextSummary) -> [UpcomingItem] {
        var out: [UpcomingItem] = []

        for event in summary.upcomingEvents {
            out.append(UpcomingItem(
                id: "event-\(event.eventId.uuidString)",
                symbol: "calendar",
                tint: .orange,
                title: event.title,
                timeLabel: relativeLabel(event.startsAt, fallback: "Sin fecha"),
                date: event.startsAt,
                destination: .event(event.eventId)
            ))
        }

        for decision in summary.openDecisions {
            out.append(UpcomingItem(
                id: "decision-\(decision.decisionId.uuidString)",
                symbol: "checkmark.bubble.fill",
                tint: .purple,
                title: decision.title,
                timeLabel: "Propuesta abierta",
                date: nil,
                destination: .decision(decision.decisionId)
            ))
        }

        for obligation in actionObligations {
            guard let due = obligation.dueAt else { continue }
            out.append(UpcomingItem(
                id: "obligation-\(obligation.id.uuidString)",
                symbol: actionKindSymbol(obligation.obligationKind),
                tint: .indigo,
                title: obligation.title ?? obligation.kindLabel,
                timeLabel: "Vence \(relativeLabel(due, fallback: ""))",
                date: due,
                destination: .obligation(obligation.id)
            ))
        }

        out.sort {
            switch ($0.date, $1.date) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }

        return Array(out.prefix(5))
    }

    private func relativeLabel(_ date: Date?, fallback: String) -> String {
        guard let date else { return fallback }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0

        let timeStr = date.formatted(date: .omitted, time: .shortened)
        switch days {
        case 0:           return "Hoy \(timeStr)"
        case 1:           return "Mañana \(timeStr)"
        case -1:          return "Ayer \(timeStr)"
        case 2...6:       return date.formatted(.dateTime.weekday(.wide)) + " \(timeStr)"
        case -6 ... -2:   return "Hace \(-days) días"
        default:
            if days > 0 && days <= 14 {
                return "En \(days) días"
            }
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    @ViewBuilder
    private func upcomingRowDestination(_ item: UpcomingItem) -> some View {
        switch item.destination {
        case .event(let id):
            NavigationLink {
                EventDetailView(eventId: id, context: context, container: container)
            } label: {
                upcomingRow(item)
            }
            .buttonStyle(.plain)
        case .decision(let id):
            NavigationLink {
                DecisionDetailView(decisionId: id, context: context, container: container)
            } label: {
                upcomingRow(item)
            }
            .buttonStyle(.plain)
        case .obligation(let id):
            Button {
                selectedObligationId = id
            } label: {
                upcomingRow(item)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func upcomingRow(_ item: UpcomingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: item.symbol)
                    .font(.callout)
                    .foregroundStyle(item.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(item.timeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Dinero (F.CONTEXT.4 — compacto)

    @ViewBuilder
    private func moneyCard(_ summary: ContextSummary) -> some View {
        let openCount = summary.openObligationsCount
        let balance = summary.money.myBalance
        let balanceTint: Color = balance < 0 ? .red : (balance > 0 ? .green : .secondary)
        NavigationLink {
            MoneyHomeView(context: context, container: container)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dinero")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text("Balance")
                            .foregroundStyle(.secondary)
                        Text(balance.currencyLabel(nil))
                            .foregroundStyle(balanceTint)
                            .fontWeight(.semibold)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(openCount == 1 ? "1 cuenta abierta" : "\(openCount) cuentas abiertas")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Soportes

    /// F.CONTEXT.4 — "Espacios dentro de [Contexto]". Cards horizontales
    /// (estilo Apple Home rooms). Solo aparece si hay hijos.
    @ViewBuilder
    private var childContextsCard: some View {
        if hierarchyStore.phase.isLoaded {
            let children = hierarchyStore.children
            if !children.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Espacios dentro de \(context.displayName)")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer()
                        if let summary = store.summary,
                           summary.can("context.tree.view"),
                           !hierarchyStore.ancestors.isEmpty || children.count > 4 {
                            NavigationLink {
                                ContextTreeView(rootContext: rootForTree(summary), container: container)
                            } label: {
                                Text("Ver todo →")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(children) { child in
                                childCarouselCard(child)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func childCarouselCard(_ child: ContextHierarchyNode) -> some View {
        // F.CONTEXT.4 fix — push real al subcontexto vía NavigationLink(value:).
        // ContextsListView registra `.navigationDestination(for: AppContext.self)`
        // que renderiza ContextHomeContainer; switchTo + recordVisit corren en
        // el `.task(id: context.id)` del child al montarse.
        if let target = container.contextStore.availableContexts.first(where: { $0.id == child.id }) {
            NavigationLink(value: target) {
                childCarouselCardLabel(child)
            }
            .buttonStyle(.plain)
        } else {
            // El backend lista el child pero el contextStore no lo tiene aún
            // (raro: caller no es miembro del child). Render disabled.
            childCarouselCardLabel(child)
                .opacity(0.5)
        }
    }

    @ViewBuilder
    private func childCarouselCardLabel(_ child: ContextHierarchyNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: child.appContext.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Spacer(minLength: 0)
            Text(child.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtypeLabel(child.actorSubtype))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 140, height: 140, alignment: .topLeading)
        .padding(12)
        .background(Theme.Surface.card, in: Theme.cardShape())
        .overlay(
            Theme.cardShape()
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func subtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "project":      return "Proyecto"
        case "trip":         return "Viaje"
        case "friend_group": return "Grupo"
        case "company":      return "Negocio"
        case "trust":        return "Trust"
        default:             return subtype
        }
    }

    private func rootForTree(_ summary: ContextSummary) -> AppContext {
        if let root = hierarchyStore.ancestors
            .sorted(by: { ($0.depth ?? 0) > ($1.depth ?? 0) })
            .first,
           let available = container.contextStore.availableContexts.first(where: { $0.id == root.id }) {
            return available
        }
        return context
    }

    /// R.2V.4 — Posibles relacionados (similarity + suggestions).
    @ViewBuilder
    private var similarContextsCard: some View {
        if similarityStore.phase.isLoaded
            && (!similarityStore.similar.isEmpty || !similarityStore.suggestions.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Posibles relacionados")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(similarityStore.similar.enumerated()), id: \.element.id) { idx, candidate in
                        similarRow(candidate)
                        if idx < similarityStore.similar.count - 1 || !similarityStore.suggestions.isEmpty {
                            Divider().padding(.leading, 16)
                        }
                    }
                    ForEach(Array(similarityStore.suggestions.enumerated()), id: \.element.id) { idx, suggestion in
                        suggestionRow(suggestion)
                        if idx < similarityStore.suggestions.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
                Text("Ruul detecta contextos parecidos por nombre, miembros y recursos. \"Ignorar\" oculta la sugerencia.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func similarRow(_ candidate: ContextSimilarityCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(.callout.weight(.medium))
                    Text("\(Int((candidate.score * 100).rounded()))% parecido")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !candidate.reasons.isEmpty {
                Text(candidate.reasons.map(\.label).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    if let target = container.contextStore.availableContexts.first(where: { $0.id == candidate.contextId }) {
                        container.contextStore.switchTo(target)
                    }
                } label: {
                    Label("Abrir", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    Task {
                        await similarityStore.dismiss(
                            subjectA: context.id,
                            subjectB: candidate.contextId,
                            type: .contextDuplicate
                        )
                    }
                } label: {
                    Label("Ignorar", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: RelationshipSuggestion) -> some View {
        let otherId = suggestion.aContextId == context.id ? suggestion.bContextId : suggestion.aContextId
        let otherName = suggestion.aContextId == context.id ? suggestion.bDisplayName : suggestion.aDisplayName
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(otherName)
                        .font(.callout.weight(.medium))
                    Text("Vincular como contenedor / contenido")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !suggestion.reasons.isEmpty {
                Text(suggestion.reasons.map(\.label).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    if let target = container.contextStore.availableContexts.first(where: { $0.id == otherId }) {
                        container.contextStore.switchTo(target)
                    }
                } label: {
                    Label("Abrir", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    Task {
                        await similarityStore.dismiss(
                            subjectA: suggestion.aContextId,
                            subjectB: suggestion.bContextId,
                            type: .relationshipContains
                        )
                    }
                } label: {
                    Label("Ignorar", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// R.2R — Compromisos (action obligations) del contexto.
    @ViewBuilder
    private var actionObligationsCard: some View {
        if !actionObligations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Compromisos pendientes (\(actionObligations.count))")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        isShowingCreateObligation = true
                    } label: {
                        Text("+ Nuevo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(actionObligations.prefix(5).enumerated()), id: \.element.id) { idx, obligation in
                        Button {
                            selectedObligationId = obligation.id
                        } label: {
                            commitmentRow(obligation, summary: store.summary)
                        }
                        .buttonStyle(.plain)
                        if idx < min(5, actionObligations.count) - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func commitmentRow(_ obligation: Obligation, summary: ContextSummary?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.indigo.badgeFill)
                    .frame(width: 32, height: 32)
                Image(systemName: actionKindSymbol(obligation.obligationKind))
                    .font(.callout)
                    .foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.title ?? obligation.kindLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let summary {
                    Text(summary.displayName(for: obligation.debtorActorId, me: myActorId))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let due = obligation.dueAt {
                Text(due.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func actionKindSymbol(_ kind: String) -> String {
        switch kind {
        case "action":      return "checkmark.circle"
        case "approval":    return "checkmark.seal"
        case "delivery":    return "shippingbox"
        case "attendance":  return "person.crop.circle.badge.checkmark"
        case "document":    return "doc.text"
        case "reservation": return "calendar.badge.clock"
        default:            return "circle.dashed"
        }
    }

    /// Reglas activas — sección menor de soporte.
    @ViewBuilder
    private func rulesCard(_ summary: ContextSummary) -> some View {
        if !summary.activeRules.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Automatizaciones (\(summary.activeRules.count))")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    NavigationLink {
                        RulesListView(context: context, container: container)
                    } label: {
                        Text("Ver todas →")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(summary.activeRules.prefix(5).enumerated()), id: \.element.id) { idx, rule in
                        ruleRow(rule)
                        if idx < min(5, summary.activeRules.count) - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: SummaryRule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.indigo.badgeFill)
                    .frame(width: 32, height: 32)
                Image(systemName: "scroll.fill")
                    .font(.callout)
                    .foregroundStyle(.indigo)
            }
            Text(rule.title)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Personal mode (Mi espacio)

    /// F.CONTEXT.2 — "Hoy": señales agregadas cross-context (saldos + atención).
    /// Convierte el contexto personal en algo vivo y útil hoy mismo, no una
    /// lista de objetos a los que tienes acceso.
    @ViewBuilder
    private var personalTodayCard: some View {
        let signals = todaySignals()
        if signals.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hoy")
                        .font(.subheadline.weight(.semibold))
                    Text("Nada pendiente 🎉")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.Surface.card, in: Theme.cardShape())
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hoy")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(signals.enumerated()), id: \.element.id) { idx, signal in
                        Button {
                            handleTodayCTA(signal.cta)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(signal.tint.opacity(0.15))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: signal.symbol)
                                        .font(.callout)
                                        .foregroundStyle(signal.tint)
                                }
                                Text(signal.label)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if signal.cta != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .disabled(signal.cta == nil)
                        if idx < signals.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    private struct TodaySignal: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let label: String
        let cta: TodayCTA?
    }

    private enum TodayCTA: Equatable {
        case openAllAttention
        case openInvitations
    }

    private func todaySignals() -> [TodaySignal] {
        var out: [TodaySignal] = []

        // Saldos agregados (sólo si hay world cargado)
        if let world = store.world {
            let owedToMe = world.openObligations.filter { !$0.iOwe }.reduce(0.0) { $0 + ($1.amount ?? 0) }
            let iOweTotal = world.openObligations.filter { $0.iOwe }.reduce(0.0) { $0 + ($1.amount ?? 0) }
            let currencyOwed = world.openObligations.first { !$0.iOwe }?.currency
            let currencyOwe  = world.openObligations.first {  $0.iOwe }?.currency

            if owedToMe > 0 {
                out.append(TodaySignal(
                    id: "money-owed",
                    symbol: "arrow.down.circle.fill",
                    tint: .green,
                    label: "Te deben \(owedToMe.currencyLabel(currencyOwed))",
                    cta: nil
                ))
            }
            if iOweTotal > 0 {
                out.append(TodaySignal(
                    id: "money-mine",
                    symbol: "arrow.up.circle.fill",
                    tint: .red,
                    label: "Debes \(iOweTotal.currencyLabel(currencyOwe))",
                    cta: nil
                ))
            }
        }

        // Atención agrupada (cross-context)
        let items = container.attentionInboxStore.items
        let votes = items.filter { $0.kind == "decision_vote" }.count
        if votes > 0 {
            out.append(TodaySignal(
                id: "votes",
                symbol: "hand.thumbsup.fill",
                tint: .purple,
                label: votes == 1 ? "1 voto pendiente" : "\(votes) votos pendientes",
                cta: .openAllAttention
            ))
        }
        let conflicts = items.filter { $0.kind == "reservation_conflict" }.count
        if conflicts > 0 {
            out.append(TodaySignal(
                id: "conflicts",
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                label: conflicts == 1 ? "1 conflicto por resolver" : "\(conflicts) conflictos por resolver",
                cta: .openAllAttention
            ))
        }
        let pays = items.filter { $0.kind == "obligation_pay" }.count
        if pays > 0 {
            out.append(TodaySignal(
                id: "pays",
                symbol: "creditcard.fill",
                tint: .green,
                label: pays == 1 ? "1 pago pendiente" : "\(pays) pagos pendientes",
                cta: .openAllAttention
            ))
        }
        let completes = items.filter { $0.kind == "obligation_complete" }.count
        if completes > 0 {
            out.append(TodaySignal(
                id: "completes",
                symbol: "checkmark.circle",
                tint: .green,
                label: completes == 1 ? "1 compromiso por marcar" : "\(completes) compromisos por marcar",
                cta: .openAllAttention
            ))
        }
        let invites = items.filter { $0.kind == "invitation" }.count
        if invites > 0 {
            out.append(TodaySignal(
                id: "invites",
                symbol: "envelope.fill",
                tint: .blue,
                label: invites == 1 ? "1 invitación" : "\(invites) invitaciones",
                cta: .openInvitations
            ))
        }

        return out
    }

    private func handleTodayCTA(_ cta: TodayCTA?) {
        switch cta {
        case .openAllAttention:
            isShowingAllAttention = true
        case .openInvitations:
            isShowingPendingInvitations = true
        case .none:
            break
        }
    }

    @ViewBuilder
    private func personalResourcesCard(_ world: MyWorld) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lo que ves (\(world.resources.count))")
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink {
                    ResourcesListView(context: context, container: container)
                } label: {
                    Text("Ver todo →")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                if world.resources.isEmpty {
                    Text("Nadie te ha compartido recursos todavía")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(world.resources.prefix(5).enumerated()), id: \.element.id) { idx, resource in
                        NavigationLink {
                            ResourceDetailView(resourceId: resource.resourceId, context: context, container: container)
                        } label: {
                            personalResourceRow(resource)
                        }
                        .buttonStyle(.plain)
                        if idx < min(5, world.resources.count) - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func personalResourceRow(_ resource: MyWorldResource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.badgeFill)
                    .frame(width: 32, height: 32)
                Image(systemName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let human = humanizedReason(resource.reasons) {
                    Text(human)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// F.CONTEXT.2 — Humaniza `MyWorldResource.reasons` (tokens del backend
    /// como `OWN`, `MANAGE`, `GOVERN`, `USE`, `BENEFICIARY`, opcionalmente
    /// `... via {context}`). Elige el rol más alto en jerarquía y devuelve UNA
    /// frase humana. Cero tokens técnicos en la UI.
    private func humanizedReason(_ reasons: [String]) -> String? {
        enum Role: Int, Comparable {
            case beneficiary = 0, use, govern, manage, own
            static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
            init?(token: String) {
                switch token.uppercased() {
                case "OWN":         self = .own
                case "MANAGE":      self = .manage
                case "GOVERN":      self = .govern
                case "USE":         self = .use
                case "BENEFICIARY": self = .beneficiary
                default: return nil
                }
            }
            var human: String {
                switch self {
                case .own:         return "Es tuyo"
                case .manage:      return "Tú lo administras"
                case .govern:      return "Tú lo gobiernas"
                case .use:         return "Puedes usarlo"
                case .beneficiary: return "Recibes beneficios"
                }
            }
        }
        var best: Role?
        for raw in reasons {
            let head = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
            if let role = Role(token: head) {
                if best == nil || role > best! { best = role }
            }
        }
        return best?.human
    }

    @ViewBuilder
    private func personalObligationsCard(_ world: MyWorld) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tus cuentas abiertas (\(world.openObligations.count))")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                if world.openObligations.isEmpty {
                    Text("No debes nada y nadie te debe 🎉")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(world.openObligations.prefix(5).enumerated()), id: \.element.id) { idx, obligation in
                        personalObligationRow(obligation)
                        if idx < min(5, world.openObligations.count) - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
            if !world.openObligations.isEmpty {
                Text("Se liquidan desde el contexto donde nacieron (Dinero → Liquidar).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func personalObligationRow(_ obligation: MyWorldObligation) -> some View {
        let tint: Color = obligation.iOwe ? .red : .green
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: obligation.iOwe ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.callout)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.contextName ?? "—")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(obligation.iOwe ? "Debes" : "Te deben")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text((obligation.amount ?? 0).currencyLabel(obligation.currency))
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers (state)

    private func loadActionObligations() async {
        guard !context.isPersonal else {
            actionObligations = []
            return
        }
        do {
            let all = try await rpc.listObligations(contextId: context.id)
            actionObligations = all.filter { $0.isActionKind && $0.isOpen }
        } catch {
            actionObligations = []
        }
    }
}

// MARK: - Wrapper Identifiable para `.sheet(item:)` con UUID.
private struct ObligationIdWrapper: Identifiable {
    let id: UUID
}

// MARK: - Sheet "Todos los pendientes" (contexto)

private struct AllContextAttentionView: View {
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
                        Image(systemName: attentionSymbol(for: item.kind))
                            .foregroundStyle(attentionTint(for: item.kind))
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

    private func attentionSymbol(for kind: String) -> String {
        switch kind {
        case "reservation_conflict": return "exclamationmark.triangle.fill"
        case "decision_vote":        return "hand.thumbsup.fill"
        case "obligation_pay":       return "creditcard.fill"
        case "obligation_complete":  return "checkmark.circle"
        case "invitation":           return "envelope.fill"
        default:                     return "circle.fill"
        }
    }

    private func attentionTint(for kind: String) -> Color {
        switch kind {
        case "reservation_conflict": return .red
        case "decision_vote":        return .purple
        case "obligation_pay",
             "obligation_complete":  return .green
        case "invitation":           return .blue
        default:                     return .secondary
        }
    }
}

#Preview("Context Home (demo)") {
    NavigationStack {
        ContextHomeView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                membershipType: "founder",
                memberCount: 5,
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}

#Preview("Contexto personal (mi mundo)") {
    NavigationStack {
        ContextHomeView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.jose,
                kind: .person,
                subtype: "person",
                displayName: "José"
            ),
            container: .demo()
        )
    }
}
