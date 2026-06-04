import SwiftUI
import RuulCore

/// Wrapper Identifiable para `.sheet(item:)` con UUID.
private struct ObligationIdWrapper: Identifiable {
    let id: UUID
}

/// F.4 — pantalla principal de un contexto. Todas las secciones salen de
/// `context_summary()`; cada una navega a su feature completo.
public struct ContextHomeView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ContextHomeStore
    /// R.2R — obligaciones de acción (kind ≠ money) del contexto. Se cargan
    /// aparte porque `context_summary().money.open_obligations` solo trae money.
    @State private var actionObligations: [Obligation] = []
    @State private var selectedObligationId: UUID?
    @State private var isShowingCreateObligation = false
    /// R.2U.3 — jerarquía padre/hijos del contexto (breadcrumb + section).
    @State private var hierarchyStore: ContextHierarchyStore
    @State private var isShowingCreateChild = false
    /// R.2V.4 — sugerencias de duplicados/relaciones cross-context.
    @State private var similarityStore: SimilarityStore

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
                    homeList(summary)
                }
            }
        }
        .navigationTitle(context.displayName)
        .navigationBarTitleDisplayMode(.large)
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
            await store.load(context: context)
            await loadActionObligations()
            if !context.isPersonal {
                await hierarchyStore.load(contextId: context.id)
                await similarityStore.load(contextId: context.id, myActorId: myActorId)
            }
        }
        .refreshable {
            await store.load(context: context)
            await loadActionObligations()
            if !context.isPersonal {
                await hierarchyStore.load(contextId: context.id)
            }
            // El pull-to-refresh también actualiza la lista de contextos del switcher.
            await container.contextStore.load()
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
            await loadActionObligations()
            if !context.isPersonal {
                await hierarchyStore.load(contextId: context.id)
            }
        }
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
    }

    private func loadActionObligations() async {
        guard !context.isPersonal else {
            actionObligations = []
            return
        }
        do {
            let all = try await rpc.listObligations(contextId: context.id)
            actionObligations = all.filter { $0.isActionKind && $0.isOpen }
        } catch {
            // Sin acceso o sin obligaciones — sección no aparece.
            actionObligations = []
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private func homeList(_ summary: ContextSummary) -> some View {
        List {
            headerSection(summary)

            if context.isPersonal {
                // Mundo personal: solo lo que my_world() agrega. Las secciones de
                // contexto (miembros, eventos, dinero del contexto, decisiones,
                // reglas) no aplican a un actor persona — siempre darían (0) y
                // contradirían los datos reales de arriba.
                if let world = store.world {
                    myWorldSections(world)
                }
            } else {
                childContextsSection(summary)
                similarContextsSection(summary)
                membersSection(summary)
                resourcesSection(summary)
                eventsSection(summary)
                obligationsSection(summary)
                actionObligationsSection(summary)
                decisionsSection(summary)
                rulesSection(summary)
                activitySection(summary)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Subcontextos (R.2U.3)

    @ViewBuilder
    private func childContextsSection(_ summary: ContextSummary) -> some View {
        // No mostrar mientras carga (evita flicker de empty state).
        if hierarchyStore.phase.isLoaded {
            Section {
                if hierarchyStore.children.isEmpty {
                    Text("Sin subcontextos todavía")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(hierarchyStore.children) { child in
                        Button {
                            if let target = container.contextStore.availableContexts.first(where: { $0.id == child.id }) {
                                container.contextStore.switchTo(target)
                            }
                        } label: {
                            InfoRow(
                                symbolName: child.appContext.symbolName,
                                title: child.name,
                                subtitle: subtypeLabel(child.actorSubtype)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Acciones gateadas por backend (my_permissions).
                if summary.can("context.children.create") {
                    Button {
                        isShowingCreateChild = true
                    } label: {
                        Label("Crear subcontexto", systemImage: "plus.rectangle.on.rectangle")
                            .font(.callout)
                    }
                }
                if summary.can("context.tree.view") &&
                   (!hierarchyStore.children.isEmpty || !hierarchyStore.ancestors.isEmpty) {
                    NavigationLink {
                        ContextTreeView(rootContext: rootForTree(summary), container: container)
                    } label: {
                        Label("Ver estructura", systemImage: "rectangle.connected.to.line.below")
                            .font(.callout)
                    }
                }
            } header: {
                Text("Subcontextos (\(hierarchyStore.children.count))")
            }
        }
    }

    // MARK: Posibles relacionados (R.2V.4)

    @ViewBuilder
    private func similarContextsSection(_ summary: ContextSummary) -> some View {
        if similarityStore.phase.isLoaded
            && (!similarityStore.similar.isEmpty || !similarityStore.suggestions.isEmpty) {
            Section {
                ForEach(similarityStore.similar) { candidate in
                    similarContextRow(candidate)
                }
                ForEach(similarityStore.suggestions) { suggestion in
                    relationshipSuggestionRow(suggestion)
                }
            } header: {
                Text("Posibles relacionados")
            } footer: {
                Text("Ruul detecta contextos parecidos por nombre, miembros y recursos. \"Ignorar\" oculta la sugerencia.")
            }
        }
    }

    @ViewBuilder
    private func similarContextRow(_ candidate: ContextSimilarityCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func relationshipSuggestionRow(_ suggestion: RelationshipSuggestion) -> some View {
        let otherId = suggestion.aContextId == context.id ? suggestion.bContextId : suggestion.aContextId
        let otherName = suggestion.aContextId == context.id ? suggestion.bDisplayName : suggestion.aDisplayName
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(otherName)
                        .font(.callout.weight(.medium))
                    Text("Sugerencia: vincular como contenedor/contenido")
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
        .padding(.vertical, 2)
    }

    /// Para el tree: si hay ancestores, usar la raíz; si no, el contexto actual.
    private func rootForTree(_ summary: ContextSummary) -> AppContext {
        if let root = hierarchyStore.ancestors
            .sorted(by: { ($0.depth ?? 0) > ($1.depth ?? 0) })
            .first,
           let available = container.contextStore.availableContexts.first(where: { $0.id == root.id }) {
            return available
        }
        return context
    }

    private func subtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family": return "Familia"
        case "community": return "Comunidad"
        case "project": return "Proyecto"
        case "trip": return "Viaje"
        case "friend_group": return "Grupo"
        case "company": return "Negocio"
        case "trust": return "Trust"
        default: return subtype
        }
    }

    // MARK: Header

    @ViewBuilder
    private func headerSection(_ summary: ContextSummary) -> some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: context.symbolName)
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.context.displayName)
                        .font(.headline)
                    HStack(spacing: 8) {
                        if context.isPersonal {
                            Text("Tu contexto personal")
                        } else {
                            Text("\(summary.membersCount) miembros")
                            if let type = context.membershipType {
                                Text("·")
                                Text(type == "founder" ? "Fundador" : "Miembro")
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            // Balance personal en el contexto
            if !context.isPersonal {
                HStack {
                    Text("Tu balance")
                    Spacer()
                    Text(summary.money.myBalance.currencyLabel(nil))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(summary.money.myBalance < 0 ? .red : (summary.money.myBalance > 0 ? .green : .secondary))
                }
            }
        }
    }

    // MARK: Mundo personal

    @ViewBuilder
    private func myWorldSections(_ world: MyWorld) -> some View {
        // R.3A — Mi Actividad: feed personalizado (subscriptions + ownership + membership).
        Section {
            NavigationLink {
                MyActivityFeedView(container: container)
            } label: {
                Label("Mi Actividad", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.callout)
            }
        } header: {
            Text("Lo que me importa")
        } footer: {
            Text("Últimas señales de los contextos, recursos y decisiones que sigues o donde tienes interés.")
        }

        Section {
            if world.resources.isEmpty {
                Text("Nadie te ha compartido recursos todavía")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(world.resources) { resource in
                    NavigationLink {
                        ResourceDetailView(resourceId: resource.resourceId, context: context, container: container)
                    } label: {
                        InfoRow(
                            symbolName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName,
                            title: resource.displayName,
                            subtitle: resource.reasons.joined(separator: " · ")
                        )
                    }
                }
            }
            NavigationLink {
                ResourcesListView(context: context, container: container)
            } label: {
                Label("Todos los recursos", systemImage: "shippingbox")
                    .font(.callout)
            }
        } header: {
            Text("Recursos que puedes ver (\(world.resources.count))")
        }

        Section {
            if world.openObligations.isEmpty {
                Text("No debes nada y nadie te debe 🎉")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(world.openObligations) { obligation in
                    InfoRow(
                        symbolName: obligation.iOwe ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                        title: obligation.contextName ?? "—",
                        subtitle: obligation.iOwe ? "Debes" : "Te deben",
                        value: (obligation.amount ?? 0).currencyLabel(obligation.currency),
                        tint: obligation.iOwe ? .red : .green
                    )
                }
            }
        } header: {
            Text("Tus cuentas abiertas (\(world.openObligations.count))")
        } footer: {
            if !world.openObligations.isEmpty {
                Text("Se liquidan desde el contexto donde nacieron (Dinero → Liquidar).")
            }
        }
    }

    // MARK: Members

    @ViewBuilder
    private func membersSection(_ summary: ContextSummary) -> some View {
        Section {
            ForEach(summary.members.prefix(5)) { member in
                HStack(spacing: 12) {
                    ActorInitialsView(name: member.displayName, size: 32)
                    Text(member.displayName)
                    Spacer()
                    if member.isAdmin {
                        StatusBadge("Admin", color: .blue)
                    }
                }
            }
            NavigationLink {
                MembersListView(context: context, container: container)
            } label: {
                Label("Todos los miembros", systemImage: "person.2")
                    .font(.callout)
            }
        } header: {
            Text("Miembros (\(summary.membersCount))")
        }
    }

    // MARK: Resources

    @ViewBuilder
    private func resourcesSection(_ summary: ContextSummary) -> some View {
        Section {
            if summary.resources.isEmpty {
                Text("Sin recursos todavía")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(summary.resources.prefix(5)) { resource in
                    NavigationLink {
                        ResourceDetailView(resourceId: resource.resourceId, context: context, container: container)
                    } label: {
                        InfoRow(
                            symbolName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName,
                            title: resource.displayName,
                            value: resource.estimatedValue.map { $0.currencyLabel(resource.currency) }
                        )
                    }
                }
            }
            NavigationLink {
                ResourcesListView(context: context, container: container)
            } label: {
                Label("Recursos", systemImage: "shippingbox")
                    .font(.callout)
            }
        } header: {
            Text("Recursos (\(summary.resourcesCount))")
        }
    }

    // MARK: Events

    @ViewBuilder
    private func eventsSection(_ summary: ContextSummary) -> some View {
        Section {
            if summary.upcomingEvents.isEmpty {
                Text("Sin eventos próximos")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(summary.upcomingEvents.prefix(5)) { event in
                    NavigationLink {
                        EventDetailView(eventId: event.eventId, context: context, container: container)
                    } label: {
                        InfoRow(
                            symbolName: (EventType(rawValue: event.eventType) ?? .other).symbolName,
                            title: event.title,
                            subtitle: event.startsAt?.formatted(date: .abbreviated, time: .shortened),
                            value: event.hostActorId.map { "Host: \(summary.displayName(for: $0, me: myActorId))" }
                        )
                    }
                }
            }
            NavigationLink {
                EventsListView(context: context, container: container)
            } label: {
                Label("Eventos", systemImage: "calendar")
                    .font(.callout)
            }
        } header: {
            Text("Próximos eventos")
        }
    }

    // MARK: Obligations

    @ViewBuilder
    private func obligationsSection(_ summary: ContextSummary) -> some View {
        Section {
            if summary.money.openObligations.isEmpty {
                Text("Nadie debe nada 🎉")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(summary.money.openObligations.prefix(5)) { obligation in
                    InfoRow(
                        symbolName: "dollarsign.circle",
                        title: "\(summary.displayName(for: obligation.debtorActorId, me: myActorId)) → \(summary.displayName(for: obligation.creditorActorId, me: myActorId))",
                        subtitle: obligationTypeLabel(obligation.obligationType),
                        value: (obligation.amount ?? 0).currencyLabel(obligation.currency)
                    )
                }
            }
            NavigationLink {
                MoneyHomeView(context: context, container: container)
            } label: {
                Label("Dinero", systemImage: "banknote")
                    .font(.callout)
            }
        } header: {
            Text("Cuentas abiertas (\(summary.openObligationsCount))")
        }
    }

    // MARK: Compromisos (R.2R action obligations)

    @ViewBuilder
    private func actionObligationsSection(_ summary: ContextSummary) -> some View {
        Section {
            if actionObligations.isEmpty {
                Text("Sin compromisos pendientes")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(actionObligations.prefix(5)) { obligation in
                    Button {
                        selectedObligationId = obligation.id
                    } label: {
                        InfoRow(
                            symbolName: actionKindSymbol(obligation.obligationKind),
                            title: obligation.title ?? obligation.kindLabel,
                            subtitle: summary.displayName(for: obligation.debtorActorId, me: myActorId),
                            value: obligation.dueAt?.formatted(date: .abbreviated, time: .omitted)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                isShowingCreateObligation = true
            } label: {
                Label("Nuevo compromiso", systemImage: "plus.circle")
                    .font(.callout)
            }
        } header: {
            Text("Compromisos pendientes (\(actionObligations.count))")
        } footer: {
            Text("Acciones que alguien del contexto se comprometió a hacer.")
        }
    }

    private func actionKindSymbol(_ kind: String) -> String {
        switch kind {
        case "action": return "checkmark.circle"
        case "approval": return "checkmark.seal"
        case "delivery": return "shippingbox"
        case "attendance": return "person.crop.circle.badge.checkmark"
        case "document": return "doc.text"
        case "reservation": return "calendar.badge.clock"
        default: return "circle.dashed"
        }
    }

    // MARK: Decisions

    @ViewBuilder
    private func decisionsSection(_ summary: ContextSummary) -> some View {
        Section {
            if summary.openDecisions.isEmpty {
                Text("Sin decisiones pendientes")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(summary.openDecisions.prefix(5)) { decision in
                    NavigationLink {
                        DecisionDetailView(decisionId: decision.decisionId, context: context, container: container)
                    } label: {
                        InfoRow(
                            symbolName: "checkmark.seal",
                            title: decision.title,
                            subtitle: (DecisionType(rawValue: decision.decisionType) ?? .generic).label
                        )
                    }
                }
            }
            NavigationLink {
                DecisionsListView(context: context, container: container)
            } label: {
                Label("Decisiones", systemImage: "checkmark.seal")
                    .font(.callout)
            }
        } header: {
            Text("Decisiones pendientes (\(summary.pendingDecisions))")
        }
    }

    // MARK: Rules

    @ViewBuilder
    private func rulesSection(_ summary: ContextSummary) -> some View {
        Section {
            if summary.activeRules.isEmpty {
                Text("Sin reglas activas")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(summary.activeRules.prefix(5)) { rule in
                    InfoRow(symbolName: "ruler", title: rule.title)
                }
            }
            NavigationLink {
                RulesListView(context: context, container: container)
            } label: {
                Label("Reglas", systemImage: "ruler")
                    .font(.callout)
            }
        } header: {
            Text("Reglas")
        }
    }

    // MARK: Activity

    @ViewBuilder
    private func activitySection(_ summary: ContextSummary) -> some View {
        Section {
            if summary.recentActivity.isEmpty {
                Text("Sin actividad todavía")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(Array(summary.recentActivity.prefix(5).enumerated()), id: \.offset) { _, activity in
                    InfoRow(
                        symbolName: "clock",
                        title: activityLabel(activity.eventType),
                        subtitle: activity.occurredAt?.formatted(.relative(presentation: .named))
                    )
                }
            }
            NavigationLink {
                ActivityFeedView(context: context, container: container)
            } label: {
                Label("Toda la actividad", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
            }
        } header: {
            Text("Actividad reciente")
        }
    }

    // MARK: - Helpers

    private func obligationTypeLabel(_ type: String) -> String {
        switch type {
        case "fine": return "Multa"
        case "expense_share": return "Parte de gasto"
        case "game_debt": return "Deuda de juego"
        case "iou": return "Saldo neto"
        default: return type
        }
    }

    private func activityLabel(_ eventType: String) -> String {
        // Reusa la taxonomía de ActivityEvent.
        ActivityEvent(id: UUID(), eventType: eventType).typeLabel
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
