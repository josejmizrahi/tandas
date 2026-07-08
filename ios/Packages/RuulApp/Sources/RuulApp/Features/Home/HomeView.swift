import SwiftUI
import RuulCore

/// Home — operacional puro: qué hago hoy.
///
/// Estructura:
/// ```
/// List(.insetGrouped) {
///   Section { hero greeting }
///   Section("Atención")     // attention_inbox cross-context (items específicos)
///   Section("Tus grupos")   // TODOS los grupos ordenados por prioridad
/// }
/// ```
///
/// Atención y Espacios responden a preguntas distintas: Atención = "qué tengo
/// que hacer", Espacios = "dónde estoy". El sort de Espacios sube primero los
/// que tienen pendientes/deuda/evento próximo, así no duplica a Atención pero
/// el contexto siempre aparece visible.
public struct HomeView: View {
    let container: DependencyContainer
    let jumpToContext: (AppContext) -> Void
    let onTriggerCreate: () -> Void
    let onOpenSettings: () -> Void
    /// R.15 — salto directo al Dinero del grupo (chips de botes/deuda).
    let jumpToContextMoney: (AppContext) -> Void

    @State private var presentedAttention: AttentionDestination?
    @State private var isShowingAllAttention = false
    @State private var overviews: [ContextOverview] = []
    @State private var quickStart: QuickStartSnapshot?
    /// 2026-06-21 — P0 #7 friend-group launch: el paso "Elegir reglas" del
    /// QuickStart abre directo la biblioteca de presets en vez de mandar a
    /// Ajustes (que mostraba Rules vacío y el usuario no descubría la library).
    @State private var presetLibraryTarget: PresetLibraryTarget?
    /// R.15 — los pasos del QuickStart abren el flujo real pre-scopeado al
    /// grupo, no superficies genéricas.
    @State private var quickStartAction: QuickStartAction?

    public init(
        container: DependencyContainer,
        jumpToContext: @escaping (AppContext) -> Void,
        onTriggerCreate: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void = {},
        jumpToContextMoney: @escaping (AppContext) -> Void = { _ in }
    ) {
        self.container = container
        self.jumpToContext = jumpToContext
        self.onTriggerCreate = onTriggerCreate
        self.onOpenSettings = onOpenSettings
        self.jumpToContextMoney = jumpToContextMoney
    }

    /// R.15 — sheets del QuickStart, scopeadas al grupo del arranque rápido.
    private enum QuickStartAction: Identifiable {
        case invite(AppContext)
        case createEvent(AppContext)
        case recordExpense(AppContext)

        var id: String {
            switch self {
            case .invite(let ctx): return "invite-\(ctx.id)"
            case .createEvent(let ctx): return "event-\(ctx.id)"
            case .recordExpense(let ctx): return "expense-\(ctx.id)"
            }
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                heroSection
                quickStartSection
                attentionSection
                spacesSection
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                // R.15 — el Home puede ser la primera pantalla en cold-launch:
                // sin contextStore cargado, los taps de grupo eran no-ops
                // silenciosos (resolveContext devolvía nil).
                if container.contextStore.availableContexts.isEmpty {
                    await container.contextStore.load()
                }
                await container.attentionInboxStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await loadOverviews()
            }
            .refreshable {
                await container.contextStore.load()
                await container.attentionInboxStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await loadOverviews()
            }
            .sheet(item: $presentedAttention) { destination in
                AttentionDestinationSheet(destination: destination, container: container)
            }
            .sheet(isPresented: $isShowingAllAttention) {
                NavigationStack {
                    AllAttentionView(container: container) { item in
                        isShowingAllAttention = false
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    }
                }
            }
            .sheet(item: $presetLibraryTarget) { target in
                RulePresetLibrarySheet(context: target.context, store: target.store)
            }
            .sheet(item: $quickStartAction) { action in
                switch action {
                case .invite(let ctx):
                    NavigationStack {
                        InviteMembersView(
                            context: ctx,
                            store: MembersStore(rpc: container.rpc),
                            container: container
                        )
                    }
                case .createEvent(let ctx):
                    CreateEventView(
                        context: ctx,
                        store: EventsStore(rpc: container.rpc),
                        container: container
                    )
                case .recordExpense(let ctx):
                    RecordExpenseView(
                        context: ctx,
                        store: MoneyStore(
                            rpc: container.rpc,
                            myActorId: container.currentActorStore.actorId
                        ),
                        container: container
                    )
                }
            }
        }
    }

    private func loadOverviews() async {
        do {
            let loaded = try await container.rpc.homeOverview()
            overviews = loaded
            await loadQuickStart(from: loaded)
        } catch {
            // Silent — la Section "Hoy en tus espacios" se oculta si vacía.
            overviews = []
            quickStart = nil
        }
    }

    // MARK: - 1. Hero greeting

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting + ",")
                    .font(.title2)
                    .foregroundStyle(Theme.Text.secondary)
                Text(container.currentActorStore.actor?.displayName ?? "Hola")
                    .font(.largeTitle.weight(.bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 16, leading: 4, bottom: 8, trailing: 4))
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Buenos días"
        case 12..<19: return "Buenas tardes"
        default:      return "Buenas noches"
        }
    }

    // MARK: - 2. Atención

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
                ForEach(items.prefix(3)) { item in
                    Button {
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    } label: {
                        attentionRow(item)
                    }
                    // R.5Z.fix.CC.2.3 (founder 2026-06-09 "y como lo doy por leido")
                    // — Apple Mail style: swipe trailing → Marcar leído. Solo
                    // visible para kinds dismissables (rule_attention_items table).
                    // Items derivados (obligation_pay/decision_vote/etc.) se
                    // cierran cuando completas la acción subyacente.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if AttentionPresentation.isDismissable(kind: item.kind) {
                            Button(role: .destructive) {
                                Task {
                                    await container.attentionInboxStore.dismiss(itemId: item.subjectId)
                                }
                            } label: {
                                Label("Marcar leído", systemImage: "checkmark.circle.fill")
                            }
                        }
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
                .foregroundStyle(priorityTint(item.derivedPriority))
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

    private func priorityTint(_ priority: AttentionPriority) -> Color {
        switch priority {
        case .critical: return Theme.Tint.critical
        case .high:     return Theme.Tint.warning
        case .normal:   return Theme.Tint.info
        case .low:      return Theme.Text.tertiary
        }
    }

    // MARK: - 2.5 Arranque rápido

    @ViewBuilder
    private var quickStartSection: some View {
        if let quickStart, !quickStart.isComplete {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quickStart.contextName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("\(quickStart.completedCount) de \(quickStart.totalCount) pasos listos")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                }
                quickStartRow(
                    title: "Invitar amigos",
                    subtitle: "Que todos puedan confirmar y dividir gastos",
                    systemImage: "person.badge.plus",
                    isDone: quickStart.hasInvitedFriends,
                    action: { openQuickStart(for: quickStart.contextId) { .invite($0) } }
                )
                quickStartRow(
                    title: "Crear próxima reunión",
                    subtitle: "Cena, viaje, juego o plan del grupo",
                    systemImage: "calendar.badge.plus",
                    isDone: quickStart.hasUpcomingEvent,
                    action: { openQuickStart(for: quickStart.contextId) { .createEvent($0) } }
                )
                quickStartRow(
                    title: "Elegir reglas",
                    subtitle: "Cómo funciona el grupo",
                    systemImage: "ruler.fill",
                    isDone: quickStart.hasRules,
                    action: { openPresetLibrary(for: quickStart.contextId) }
                )
                quickStartRow(
                    title: "Registrar primer gasto",
                    subtitle: "Para ver saldos y liquidar",
                    systemImage: "receipt.fill",
                    isDone: quickStart.hasMoneyActivity,
                    action: { openQuickStart(for: quickStart.contextId) { .recordExpense($0) } }
                )
            } header: {
                Text("Arranque rápido")
            } footer: {
                Text("Completa estos pasos para que el grupo pueda usar Ruul en menos de 5 minutos.")
            }
        }
    }

    @ViewBuilder
    private func quickStartRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isDone: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : systemImage)
                    .foregroundStyle(isDone ? Theme.Tint.success : Theme.Tint.primary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !isDone {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func loadQuickStart(from overviews: [ContextOverview]) async {
        let collectives = overviews.filter { $0.actorKind != "person" }
        guard let overview = collectives.sorted(by: bySpacesPriority).first else {
            quickStart = nil
            return
        }

        async let rulesTask: [Rule]? = try? container.rpc.listRules(contextId: overview.contextActorId)
        async let obligationsTask: [Obligation]? = try? container.rpc.listObligations(contextId: overview.contextActorId)
        let (rules, obligations) = await (rulesTask ?? [], obligationsTask ?? [])
        let moneyTypes: Set<String> = ["expense_share", "iou", "contribution", "dues", "game_debt", "trip_share"]
        quickStart = QuickStartSnapshot(
            contextId: overview.contextActorId,
            contextName: overview.displayName,
            hasInvitedFriends: overview.memberCount > 1,
            hasUpcomingEvent: overview.nextEventAt != nil,
            hasRules: rules.contains { $0.isActive },
            hasMoneyActivity: obligations.contains { $0.isMoneyKind && moneyTypes.contains($0.obligationType) }
        )
    }

    // MARK: - 3. Tus grupos

    /// Una sola sección con TODOS los grupos, ordenados por
    /// prioridad: pendientes desc → deuda → próximo evento → último visitado.
    /// Siempre visible (siempre que haya al menos un collective); los
    /// actionables suben de forma natural sin necesidad de un fallback.
    @ViewBuilder
    private var spacesSection: some View {
        let collectives = overviews.filter { $0.actorKind != "person" }
        let sorted = collectives.sorted(by: bySpacesPriority)
        let visible = Array(sorted.prefix(6))
        let hidden = max(0, sorted.count - visible.count)
        if !visible.isEmpty {
            Section {
                ForEach(visible) { overview in
                    spaceRow(overview)
                        .contentShape(Rectangle())
                        .onTapGesture { openOverview(overview) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                openOverview(overview, money: true)
                            } label: {
                                Label("Dinero", systemImage: "dollarsign.circle.fill")
                            }
                            .tint(Theme.Tint.success)
                        }
                }
            } header: {
                Text("Tus grupos")
            } footer: {
                if hidden > 0 {
                    Text("Y \(hidden) más desde Ajustes > Grupo.")
                }
            }
        }
    }

    /// Sort estable: pendientes desc → deuda (balance < 0) → próximo evento
    /// (más cercano primero) → último visitado.
    private func bySpacesPriority(_ a: ContextOverview, _ b: ContextOverview) -> Bool {
        if a.pendingCount != b.pendingCount { return a.pendingCount > b.pendingCount }
        let aDebt = (a.myBalance ?? 0) < 0
        let bDebt = (b.myBalance ?? 0) < 0
        if aDebt != bDebt { return aDebt }
        let aEvent = a.nextEventAt ?? .distantFuture
        let bEvent = b.nextEventAt ?? .distantFuture
        if aEvent != bEvent { return aEvent < bEvent }
        let aVisit = a.lastVisitedAt ?? .distantPast
        let bVisit = b.lastVisitedAt ?? .distantPast
        return aVisit > bVisit
    }

    @ViewBuilder
    private func spaceRow(_ overview: ContextOverview) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(overview.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    if overview.pendingCount > 0 {
                        // R.15 — el chip de pendientes abre la lista de atención.
                        Button {
                            isShowingAllAttention = true
                        } label: {
                            Text("\(overview.pendingCount)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.Tint.warning.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.Tint.warning)
                        }
                        .buttonStyle(.borderless)
                    }
                    // R.14.B — chip "💰 $X" si el grupo tiene botes abiertos.
                    // R.15 — tap directo al Dinero del grupo.
                    if let poolsTotal = overview.poolsTotal,
                       let currency = overview.poolsCurrency,
                       poolsTotal > 0 {
                        Button {
                            openOverview(overview, money: true)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "banknote.fill")
                                    .font(.caption2)
                                Text(poolsTotal.compactCurrencyLabel(currency))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.Tint.success.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Tint.success)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let caption = spaceCaption(overview) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(spaceCaptionTint(overview))
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: overviewSymbol(overview))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(spaceCaptionTint(overview))
        }
    }

    /// Caption por prioridad: pendientes > deuda > evento próximo > saldo a favor
    /// > membresía. Nil si no hay nada que decir (fallback silencioso).
    private func spaceCaption(_ overview: ContextOverview) -> String? {
        if overview.pendingCount > 0 {
            return overview.pendingCount == 1 ? "1 pendiente" : "\(overview.pendingCount) pendientes"
        }
        if let balance = overview.myBalance, let currency = overview.balanceCurrency, balance < 0 {
            return "Debes " + balance.compactCurrencyLabel(currency)
        }
        if let when = overview.nextEventAt, let title = overview.nextEventTitle {
            return "\(eventWhen(when)) · \(title)"
        }
        if let balance = overview.myBalance, let currency = overview.balanceCurrency, balance > 0 {
            return "Te deben " + balance.compactCurrencyLabel(currency)
        }
        // R.14.B — última actividad (fallback antes de "X miembros"). Sólo
        // surface si fue dentro de los últimos 30 días: si fue hace 2 meses
        // mostrarla no aporta valor.
        if let last = overview.lastActivityAt,
           let label = relativeActivityLabel(last) {
            return label
        }
        if overview.memberCount > 1 {
            return "\(overview.memberCount) miembros"
        }
        return nil
    }

    /// R.14.B — etiqueta relativa "Hoy"/"Ayer"/"Hace N días" para `last_activity_at`.
    /// Devuelve nil si la actividad es > 30 días (silencioso) o vino del futuro.
    private func relativeActivityLabel(_ date: Date) -> String? {
        let now = Date()
        let delta = now.timeIntervalSince(date)
        guard delta > 0 else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Activo hoy" }
        if cal.isDateInYesterday(date) { return "Activo ayer" }
        let days = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if days <= 7 { return "Activo hace \(days) días" }
        if days <= 14 { return "Activo hace 1 semana" }
        if days <= 30 { return "Activo hace \(days / 7) semanas" }
        return nil
    }

    private func spaceCaptionTint(_ overview: ContextOverview) -> Color {
        if overview.pendingCount > 0 { return Theme.Tint.warning }
        if let balance = overview.myBalance, balance < 0 { return Theme.Tint.critical }
        if overview.nextEventAt != nil { return Theme.Tint.primary }
        if let balance = overview.myBalance, balance > 0 { return Theme.Tint.success }
        return Theme.Text.secondary
    }

    private func eventWhen(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Hoy " + date.formatted(.dateTime.hour().minute())
        }
        if cal.isDateInTomorrow(date) {
            return "Mañana " + date.formatted(.dateTime.hour().minute())
        }
        let days = cal.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.wide)).capitalized
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func overviewSymbol(_ overview: ContextOverview) -> String {
        if overview.actorKind == "person" { return "person.crop.circle.fill" }
        switch overview.actorSubtype {
        case "family":       return "figure.2.and.child.holdinghands"
        case "trip":         return "airplane"
        case "community":    return "person.3.fill"
        case "friend_group": return "person.3.fill"
        case "project":      return "hammer.fill"
        case "company":      return "building.2.fill"
        case "trust":        return "building.columns.fill"
        default:             return "rectangle.split.2x1.fill"
        }
    }

    private func resolveContext(_ id: UUID) -> AppContext? {
        container.contextStore.availableContexts.first { $0.id == id }
    }

    /// R.15 — abre el grupo (o su Dinero) garantizando que el contextStore
    /// esté cargado; antes el tap era un no-op silencioso en cold-launch.
    private func openOverview(_ overview: ContextOverview, money: Bool = false) {
        Task {
            if resolveContext(overview.contextActorId) == nil {
                await container.contextStore.load()
            }
            guard let ctx = resolveContext(overview.contextActorId) else { return }
            if money {
                jumpToContextMoney(ctx)
            } else {
                jumpToContext(ctx)
            }
        }
    }

    /// R.15 — resuelve el contexto del QuickStart (cargando si hace falta) y
    /// presenta la sheet del flujo real.
    private func openQuickStart(for contextId: UUID, _ make: @escaping (AppContext) -> QuickStartAction) {
        Task {
            if resolveContext(contextId) == nil {
                await container.contextStore.load()
            }
            guard let ctx = resolveContext(contextId) else { return }
            quickStartAction = make(ctx)
        }
    }

}

// MARK: - Preset library shortcut (P0 #7)

/// Wrapper Identifiable para `.sheet(item:)` de la biblioteca de presets.
private struct PresetLibraryTarget: Identifiable {
    let id: UUID
    let context: AppContext
    let store: RulesStore
}

extension HomeView {
    fileprivate func openPresetLibrary(for contextId: UUID) {
        guard let context = resolveContext(contextId) else { return }
        let store = RulesStore(rpc: container.rpc)
        presetLibraryTarget = PresetLibraryTarget(id: contextId, context: context, store: store)
    }
}

private struct QuickStartSnapshot {
    let contextId: UUID
    let contextName: String
    let hasInvitedFriends: Bool
    let hasUpcomingEvent: Bool
    let hasRules: Bool
    let hasMoneyActivity: Bool

    var totalCount: Int { 4 }
    var completedCount: Int {
        [
            hasInvitedFriends,
            hasUpcomingEvent,
            hasRules,
            hasMoneyActivity
        ].filter { $0 }.count
    }
    var isComplete: Bool { completedCount == totalCount }
}

// MARK: - Sheet "Todos los pendientes"

private struct AllAttentionView: View {
    let container: DependencyContainer
    let onTap: (AttentionItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(container.attentionInboxStore.items) { item in
                Button {
                    onTap(item)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: AttentionPresentation.symbol(for: item.kind))
                            .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.medium))
                            Text("\(item.contextDisplayName) · \(item.reason)")
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

#Preview("Home (demo)") {
    HomeView(container: .demo(), jumpToContext: { _ in }, onTriggerCreate: {})
}
