import SwiftUI
import RuulCore

/// R.8.MiMundo.S1 (2026-06-10) — Founder firma "Yo = mi mundo completo":
/// el espacio personal deja de ser una lista plana de bookmarks y pasa a la
/// doctrina canónica Detail §0.2 (Hero / Atención / Dashboard / Mi mundo /
/// Configuración / Cerrar sesión).
///
/// Slice 1: shell + cross-context aggregators existentes (Calendario, Actividad,
/// Recursos, Suscripciones, Red de confianza). Slice 2 conecta las acciones
/// personales (Subir recurso, Crear compromiso, etc.) con el contexto personal
/// preselected. Slices 3-7 agregan MyObligationsView, MyDecisionsView,
/// MyDocumentsView, MyReservationsView, MyRulesView + balance neto derivado.
///
/// Por qué el title es "Mi mundo" y la tab "Yo": la tab es pronombre corto;
/// el título describe el contenido (todo lo que toco en Ruul cross-context).
public struct MeView: View {
    let container: DependencyContainer
    /// F.NAV.6 — jump al tab Contextos desde la sección "Mis contextos".
    let goToContexts: () -> Void

    @State private var world: MyWorld?
    @State private var isShowingSettings = false
    @State private var isShowingEditProfile = false
    @State private var presentedAttention: AttentionDestination?
    /// R.8.MiMundo.S2 — sheet única para las 8 acciones personales. Cada acción
    /// abre su Create* respectivo con el contexto personal preselected.
    @State private var presentedAction: PersonalAction?
    /// R.8.MiMundo.S7 — métricas agregadas cross-context. Fan-out lightweight
    /// sobre `listObligations` por contexto. Se cargan en background — los
    /// chips degradan a "—" mientras llega el dato.
    @State private var openObligationsCount: Int = 0
    @State private var netBalances: [(currency: String, amount: Double)] = []
    /// R.8.MiMundo.S8 — resumen on-device "Esta semana en tu mundo".
    /// FoundationModels graceful degradation: si Apple Intelligence no está
    /// disponible, la sección se oculta entera.
    @State private var summaryService = ActivitySummaryService()
    /// D3 (re-audit 2026-06-14) — confirmation antes de cerrar sesión.
    @State private var isConfirmingSignOut = false

    // Stores eagerly instanciados — mismo patrón que `FormDestination` en
    // `CreateIntentSheet`: lazy `@State?` + `.task` resulta frágil cuando
    // SwiftUI re-renderiza el sheet antes de que el task complete.
    @State private var resourcesStore: ResourcesStore
    @State private var eventsStore: EventsStore
    @State private var moneyStore: MoneyStore
    @State private var rulesStore: RulesStore

    public init(container: DependencyContainer, goToContexts: @escaping () -> Void) {
        self.container = container
        self.goToContexts = goToContexts
        _resourcesStore = State(initialValue: ResourcesStore(rpc: container.rpc))
        _eventsStore = State(initialValue: EventsStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
        _moneyStore = State(initialValue: MoneyStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
        _rulesStore = State(initialValue: RulesStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            List {
                heroSection
                aiSummarySection
                attentionSection
                actionsSection
                myWorldSection
                configurationSection
                signOutSection
            }
            .listStyle(.insetGrouped)
            // Fase 9.7 — spacing compact consistente con ContextDetailV2.
            .listSectionSpacing(.compact)
            .navigationTitle("Mi mundo")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadWorld()
                await container.attentionInboxStore.load()
                await loadObligationsSummary()
            }
            .refreshable {
                await loadWorld()
                await container.attentionInboxStore.load()
                await loadObligationsSummary()
            }
            .sheet(isPresented: $isShowingSettings) {
                PersonalSettingsView(container: container)
            }
            .sheet(isPresented: $isShowingEditProfile) {
                EditProfileView(container: container)
            }
            .sheet(item: $presentedAttention) { destination in
                AttentionDestinationSheet(destination: destination, container: container)
            }
            .sheet(item: $presentedAction) { action in
                personalActionDestination(action)
            }
        }
    }

    // MARK: - 1. Hero (avatar + nombre + métricas chips)

    @ViewBuilder
    private var heroSection: some View {
        let displayName = container.currentActorStore.actor?.displayName ?? "—"
        let contextCount = container.contextStore.availableContexts
            .filter { $0.isRoot && !$0.isPersonal }
            .count
        let resourcesCount = world?.resources.count ?? 0

        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    ActorInitialsView(name: displayName, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        Text("Mi mundo en Ruul")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        isShowingEditProfile = true
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.Tint.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Editar perfil")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        metricChip(
                            value: "\(contextCount)",
                            label: contextCount == 1 ? "espacio" : "espacios",
                            systemImage: "square.grid.2x2.fill",
                            tint: Theme.Tint.primary
                        )
                        metricChip(
                            value: "\(resourcesCount)",
                            label: resourcesCount == 1 ? "recurso" : "recursos",
                            systemImage: "shippingbox.fill",
                            tint: Theme.Tint.warning
                        )
                        metricChip(
                            value: openObligationsCount > 0 ? "\(openObligationsCount)" : "0",
                            label: openObligationsCount == 1 ? "compromiso" : "compromisos",
                            systemImage: "checklist",
                            tint: Theme.Tint.info
                        )
                        metricChip(
                            value: balanceChipValue,
                            label: balanceChipLabel,
                            systemImage: "scalemass.fill",
                            tint: balanceChipTint
                        )
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func metricChip(value: String, label: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Text.primary)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Text.secondary)
        }
        .frame(minWidth: 78, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 1b. AI summary (Esta semana en tu mundo)

    @ViewBuilder
    private var aiSummarySection: some View {
        // Si Apple Intelligence no está disponible (sin Pro / no eligible),
        // ocultamos la sección entera — el resto de Yo sigue siendo funcional.
        if summaryService.isAvailable {
            Section {
                aiSummaryContent
            } header: {
                Label("Esta semana en tu mundo", systemImage: "sparkles")
                    .foregroundStyle(.purple)
            } footer: {
                Text("Resumen generado en tu dispositivo con Apple Intelligence.")
            }
        }
    }

    @ViewBuilder
    private var aiSummaryContent: some View {
        switch summaryService.phase {
        case .idle:
            Button {
                Task { await runSummary() }
            } label: {
                Label("Generar resumen", systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Pensando…")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
        case .loaded(let text):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task {
                        summaryService.reset()
                        await runSummary()
                    }
                } label: {
                    Label("Generar otra", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "sparkles.slash")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(Theme.Tint.critical)
        }
    }

    /// Construye el input agregado para el modelo: counts + highlights.
    /// El modelo lo convierte en una frase narrativa en español.
    private func buildSummaryInput() -> String {
        let contextCount = container.contextStore.availableContexts
            .filter { $0.isRoot && !$0.isPersonal }
            .count
        let resourcesCount = world?.resources.count ?? 0
        let attention = container.attentionInboxStore.items
        let attentionKinds = Set(attention.map { $0.kind })
        var lines: [String] = []
        lines.append("contextos_activos: \(contextCount)")
        lines.append("recursos_visibles: \(resourcesCount)")
        lines.append("compromisos_abiertos: \(openObligationsCount)")
        if !netBalances.isEmpty, let dominant = netBalances.first {
            let signo = dominant.amount > 0 ? "a_favor" : "en_contra"
            lines.append("balance_dominante: \(Int(dominant.amount)) \(dominant.currency) \(signo)")
        }
        lines.append("pendientes_atencion: \(attention.count)")
        if !attentionKinds.isEmpty {
            let kindsList = attentionKinds.sorted().joined(separator: ",")
            lines.append("tipos_pendientes: \(kindsList)")
        }
        if attention.count > 0 {
            let top = attention.prefix(3).map { $0.title }.joined(separator: " | ")
            lines.append("top_pendientes: \(top)")
        }
        return lines.joined(separator: "\n")
    }

    private func runSummary() async {
        await summaryService.summarize(input: buildSummaryInput())
    }

    // MARK: - 2. Atención (cross-context inbox)

    @ViewBuilder
    private var attentionSection: some View {
        let items = container.attentionInboxStore.items
        Section {
            if items.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo al día").font(.callout.weight(.medium))
                        Text("Sin pendientes en este momento")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
            } else {
                ForEach(items.prefix(5)) { item in
                    Button {
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    } label: {
                        attentionRow(item)
                    }
                }
                if items.count > 5 {
                    Text("\(items.count - 5) pendientes más en Home")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
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
                .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(item.contextDisplayName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 3. Acciones personales (crear cualquier primitiva desde Yo)
    //
    // Slice 7.A.6 (audit 2026-06-14) — split visual en 2 sections para que el
    // usuario entienda cuáles crean cosas en su espacio personal y cuáles
    // afectan a espacios colectivos. Antes 8 acciones en una sola lista hacían
    // que pareciera todo equivalente.

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            actionRow(
                .resource,
                label: "Subir recurso propio",
                systemImage: "shippingbox.fill",
                tint: Theme.Tint.warning
            )
            actionRow(
                .expense,
                label: "Registrar gasto personal",
                systemImage: "creditcard.fill",
                tint: Theme.Tint.success
            )
            actionRow(
                .obligation,
                label: "Crear compromiso",
                systemImage: "checklist",
                tint: Theme.Tint.info
            )
            actionRow(
                .event,
                label: "Agendar evento personal",
                systemImage: "calendar.badge.plus",
                tint: Theme.Tint.primary
            )
            actionRow(
                .rule,
                label: "Crear regla personal",
                systemImage: "sparkles",
                tint: .purple
            )
            actionRow(
                .decision,
                label: "Crear decisión personal",
                systemImage: "checkmark.bubble.fill",
                tint: .indigo
            )
        } header: {
            Text("Crear en mi espacio")
        } footer: {
            Text("Lo que crees aquí vive en tu espacio personal. Después puedes compartirlo con cualquier espacio.")
        }

        Section {
            actionRow(
                .context,
                label: "Crear espacio nuevo",
                systemImage: "rectangle.split.2x1.fill",
                tint: Theme.Tint.primary
            )
            actionRow(
                .joinCode,
                label: "Unirme por código",
                systemImage: "key.fill",
                tint: Theme.Tint.info
            )
        } header: {
            Text("Espacios")
        } footer: {
            Text("Crea un grupo nuevo o únete a uno con el código que te compartieron.")
        }
    }

    @ViewBuilder
    private func actionRow(_ action: PersonalAction, label: String, systemImage: String, tint: Color) -> some View {
        Button {
            presentedAction = action
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Dispatch del sheet item `presentedAction` al Create* correspondiente.
    /// Las 6 acciones context-scoped reusan el contexto personal del usuario
    /// (`isPersonal=true`). `CreateContextView` y `JoinByCodeView` no requieren
    /// contexto.
    @ViewBuilder
    private func personalActionDestination(_ action: PersonalAction) -> some View {
        switch action {
        case .context:
            CreateContextView(container: container)
        case .joinCode:
            JoinByCodeView(container: container)
        case .resource, .expense, .obligation, .event, .rule, .decision:
            if let personal = container.contextStore.availableContexts.first(where: { $0.isPersonal }) {
                contextActionDestination(action, context: personal)
            } else {
                // Defensa: el shell debería montar `ensure_person_actor` antes de
                // MainTabShell. Si por alguna razón el personal context no está,
                // damos UX honesto en vez de crashear.
                ContentUnavailableView(
                    "Tu espacio personal aún no está listo",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Vuelve a abrir esta acción en unos segundos.")
                )
            }
        }
    }

    @ViewBuilder
    private func contextActionDestination(_ action: PersonalAction, context: AppContext) -> some View {
        switch action {
        case .resource:
            CreateResourceFlow(context: context, store: resourcesStore, container: container)
        case .expense:
            RecordExpenseView(context: context, store: moneyStore, container: container)
        case .obligation:
            CreateObligationView(context: context, container: container)
        case .event:
            CreateEventView(context: context, store: eventsStore, container: container)
        case .rule:
            CreateRuleWizard(context: context, store: rulesStore, rpc: container.rpc)
        case .decision:
            // CreateDecisionView no trae NavigationStack propio — lo envolvemos
            // como hace `FormDestination` en CreateIntentSheet.
            NavigationStack {
                CreateDecisionView(context: context, container: container)
                    .navigationTitle("Nueva decisión")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            MeDismissButton()
                        }
                    }
            }
        case .context, .joinCode:
            EmptyView()
        }
    }

    // MARK: - 4. Mi mundo (agregadores cross-context)
    //
    // 4 primary rows visibles + acordeón "Más" con 7 destinos secundarios.
    // Reduce el wall de 11 NavigationLinks a 5 rows arrancando colapsado.

    @ViewBuilder
    private var myWorldSection: some View {
        Section {
            Button {
                goToContexts()
            } label: {
                HStack {
                    Label("Mis espacios", systemImage: "square.grid.2x2.fill")
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .buttonStyle(.plain)
            NavigationLink {
                MyCalendarView(container: container)
            } label: {
                Label("Mi calendario", systemImage: "calendar")
            }
            NavigationLink {
                MyActivityFeedView(container: container)
            } label: {
                Label("Mi actividad", systemImage: "antenna.radiowaves.left.and.right")
            }
            NavigationLink {
                MyBalanceView(container: container)
            } label: {
                Label("Mi balance neto", systemImage: "scalemass.fill")
            }
            DisclosureGroup {
                NavigationLink {
                    MyResourcesView(container: container)
                } label: {
                    Label("Mis recursos", systemImage: "shippingbox.fill")
                }
                NavigationLink {
                    MyObligationsView(container: container)
                } label: {
                    Label("Mis compromisos", systemImage: "checklist")
                }
                NavigationLink {
                    MyReservationsView(container: container)
                } label: {
                    Label("Mis reservaciones", systemImage: "calendar.badge.clock")
                }
                NavigationLink {
                    MyDecisionsView(container: container)
                } label: {
                    Label("Mis decisiones", systemImage: "checkmark.bubble.fill")
                }
                NavigationLink {
                    MyRulesView(container: container)
                } label: {
                    Label("Mis reglas", systemImage: "sparkles")
                }
                NavigationLink {
                    MyDocumentsView(container: container)
                } label: {
                    Label("Mis documentos", systemImage: "doc.text.fill")
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
            } label: {
                Label("Más", systemImage: "ellipsis.circle")
                    .font(.callout.weight(.medium))
            }
        } header: {
            Text("Mi mundo")
        }
    }

    // MARK: - 5. Configuración
    //
    // "Editar perfil" sale de aquí — el lápiz del Hero ya cumple esa función
    // (un solo entry-point para editar perfil, Apple-style).

    @ViewBuilder
    private var configurationSection: some View {
        Section {
            Button {
                isShowingSettings = true
            } label: {
                HStack {
                    Label("Ajustes", systemImage: "gearshape")
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Configuración")
        }
    }

    // MARK: - 7. Cerrar sesión

    @ViewBuilder
    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .confirmationDialog(
            "¿Cerrar sesión?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Cerrar sesión", role: .destructive) {
                Task { await container.signOut() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tu sesión se cerrará en este dispositivo.")
        }
    }

    // MARK: - Balance chip derivations

    /// Valor a mostrar en el chip de balance: moneda dominante (mayor |amount|).
    /// "—" mientras no haya carga, "0" cuando explícitamente estás a 0.
    private var balanceChipValue: String {
        guard !netBalances.isEmpty else { return "—" }
        guard let dominant = netBalances.first else { return "0" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = dominant.currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: dominant.amount)) ?? "\(Int(dominant.amount))"
    }

    private var balanceChipLabel: String {
        if netBalances.count > 1 {
            let extras = netBalances.count - 1
            return "+ \(extras) moneda\(extras == 1 ? "" : "s")"
        }
        return "balance"
    }

    private var balanceChipTint: Color {
        guard let dominant = netBalances.first else { return Theme.Tint.success }
        if dominant.amount > 0 { return Theme.Tint.success }
        if dominant.amount < 0 { return Theme.Tint.warning }
        return Theme.Tint.success
    }

    // MARK: - Data

    private func loadWorld() async {
        do {
            world = try await container.rpc.myWorld()
        } catch {
            // Métricas se degradan gracefully a "—". No bloqueamos la UI por
            // un fallo de myWorld() — el resto del shell sigue siendo útil.
            world = nil
        }
    }

    /// R.8.MiMundo.S7 — Fan-out cross-context para `compromisos` y `balance`
    /// chips del Hero. Mismo cálculo que `MyBalanceView` / `MyObligationsView`
    /// pero a nivel resumen. Tolerante a fallos parciales (`try?`).
    private func loadObligationsSummary() async {
        let myActorId = container.currentActorStore.actorId
        let contexts = container.contextStore.availableContexts
        guard let myActorId, !contexts.isEmpty else { return }
        var openCount = 0
        var balances: [String: Double] = [:]
        await withTaskGroup(of: [Obligation].self) { group in
            for ctx in contexts {
                group.addTask {
                    (try? await container.rpc.listObligations(contextId: ctx.id)) ?? []
                }
            }
            for await obligations in group {
                for o in obligations {
                    guard o.debtorActorId == myActorId || o.creditorActorId == myActorId else { continue }
                    let isActive = o.isOpen || o.status == "accepted" || o.status == "in_progress"
                    if isActive { openCount += 1 }
                    if isActive, o.isMoneyKind, let amount = o.amount, let currency = o.currency {
                        let signed = o.debtorActorId == myActorId ? -amount : amount
                        balances[currency, default: 0] += signed
                    }
                }
            }
        }
        openObligationsCount = openCount
        netBalances = balances
            .filter { abs($0.value) > 0.005 }
            .map { (currency: $0.key, amount: $0.value) }
            .sorted { abs($0.amount) > abs($1.amount) }
    }
}

// MARK: - Personal action identifier

/// R.8.MiMundo.S2 — identifier para `sheet(item:)`. El payload es solo el tipo
/// de acción; el contexto personal se resuelve dentro de `MeView` al construir
/// el destino.
private enum PersonalAction: String, Identifiable {
    case resource, expense, obligation, event, rule, decision, context, joinCode
    var id: String { rawValue }
}

/// Botón Cancelar para los sheets que necesitan envoltorio (e.g. CreateDecisionView).
/// Replica el helper privado homónimo de `CreateIntentSheet`.
private struct MeDismissButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button("Cancelar") { dismiss() }
    }
}

#Preview("Mi mundo (demo)") {
    MeView(container: .demo(), goToContexts: {})
}
