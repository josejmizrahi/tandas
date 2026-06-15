import SwiftUI
import RuulCore

/// R.11.E.2 — Home rediseño (founder firmado 2026-06-16). Diferenciación
/// fuerte de roles con Contextos:
///
///   **HOME = "Hoy en Ruul"** (operacional puro — qué hago).
///   **CONTEXTOS = "Tus espacios"** (catálogo rico — dónde estoy).
///
/// Cambios vs R.5V.3:
/// - Quitar **"Continuar"** carousel → vivirá en Contextos como sort default.
/// - Quitar **"Actividad reciente"** → ya tiene tab dedicada 🔔 (MyActivityFeedView).
/// - Agregar **"Hoy en tus espacios"** → row por contexto con actividad
///   actionable hoy (pendientes, próximo evento ≤ 7d, balance ≠ 0). Powered
///   by `home_overview()` RPC (R.11.E.0).
///
/// Estructura:
/// ```
/// List(.insetGrouped) {
///   Section { hero greeting }
///   Section("Atención")            // attention_inbox cross-context (sin cambio)
///   Section("Hoy en tus espacios") // NUEVO — contextos con next_event ≤ 7d O pendientes O balance ≠ 0
///   Section("Próximamente")        // tools placeholders
/// }
/// ```
public struct HomeView: View {
    let container: DependencyContainer
    let jumpToContext: (AppContext) -> Void
    let onTriggerCreate: () -> Void

    @State private var presentedAttention: AttentionDestination?
    @State private var isShowingAllAttention = false
    @State private var overviews: [ContextOverview] = []

    public init(container: DependencyContainer, jumpToContext: @escaping (AppContext) -> Void, onTriggerCreate: @escaping () -> Void) {
        self.container = container
        self.jumpToContext = jumpToContext
        self.onTriggerCreate = onTriggerCreate
    }

    public var body: some View {
        NavigationStack {
            List {
                heroSection
                attentionSection
                todaySection
                exploreSection
                toolsSection
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await container.attentionInboxStore.load()
                await container.invitationsStore.load(actorId: container.currentActorStore.actorId)
                await loadOverviews()
            }
            .refreshable {
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
        }
    }

    private func loadOverviews() async {
        do {
            overviews = try await container.rpc.homeOverview()
        } catch {
            // Silent — la Section "Hoy en tus espacios" se oculta si vacía.
            overviews = []
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

    // MARK: - 3. Hoy en tus espacios (R.11.E.2 — actionable contexts cross-context)

    @ViewBuilder
    private var todaySection: some View {
        let actionable = overviews
            .filter { $0.isActionableToday() }
            .sorted { byTodayPriority($0, $1) }
        if !actionable.isEmpty {
            Section {
                ForEach(actionable.prefix(5)) { overview in
                    Button {
                        if let ctx = resolveContext(overview.contextActorId) {
                            jumpToContext(ctx)
                        }
                    } label: {
                        todayRow(overview)
                    }
                }
            } header: {
                Text("Hoy en tus espacios")
            }
        }
    }

    /// Sort: pendientes primero (más actionable), luego balance negativo,
    /// luego próximos eventos por fecha.
    private func byTodayPriority(_ a: ContextOverview, _ b: ContextOverview) -> Bool {
        if a.pendingCount != b.pendingCount { return a.pendingCount > b.pendingCount }
        let aDebt = (a.myBalance ?? 0) < 0
        let bDebt = (b.myBalance ?? 0) < 0
        if aDebt != bDebt { return aDebt }
        let aEvent = a.nextEventAt ?? .distantFuture
        let bEvent = b.nextEventAt ?? .distantFuture
        return aEvent < bEvent
    }

    @ViewBuilder
    private func todayRow(_ overview: ContextOverview) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(overview.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    if overview.pendingCount > 0 {
                        Text("\(overview.pendingCount)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.Tint.warning.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                Text(todayCaption(overview))
                    .font(.caption)
                    .foregroundStyle(todayCaptionTint(overview))
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: overviewSymbol(overview))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(todayCaptionTint(overview))
        }
    }

    /// Surface por prioridad: pendientes > balance < 0 > próximo evento > balance > 0.
    private func todayCaption(_ overview: ContextOverview) -> String {
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
        return ""
    }

    private func todayCaptionTint(_ overview: ContextOverview) -> Color {
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

    // MARK: - 4. Explora (R.11.G — empty state inteligente)

    /// Cuando "Hoy en tus espacios" NO tiene items actionable, Home se vería
    /// casi vacío (sólo Saludo + Atención + Próximamente). Surface top 3
    /// espacios por last_visited para que el founder siempre tenga un
    /// entry-point visible sin ir a la tab Contextos.
    @ViewBuilder
    private var exploreSection: some View {
        let hasActionable = overviews.contains { $0.isActionableToday() }
        if !hasActionable {
            let topRecents = overviews
                .filter { $0.actorKind != "person" }
                .sorted { ($0.lastVisitedAt ?? .distantPast) > ($1.lastVisitedAt ?? .distantPast) }
                .prefix(3)
            if !topRecents.isEmpty {
                Section {
                    ForEach(Array(topRecents)) { overview in
                        Button {
                            if let ctx = resolveContext(overview.contextActorId) {
                                jumpToContext(ctx)
                            }
                        } label: {
                            exploreRow(overview)
                        }
                    }
                } header: {
                    Text("Mis espacios")
                } footer: {
                    Text("Todo al día — explora tus espacios.")
                }
            }
        }
    }

    @ViewBuilder
    private func exploreRow(_ overview: ContextOverview) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if overview.memberCount > 1 {
                    Text("\(overview.memberCount) miembros")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        } icon: {
            Image(systemName: overviewSymbol(overview))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.primary)
        }
    }

    // MARK: - 5. Herramientas (Próximamente)

    @ViewBuilder
    private var toolsSection: some View {
        Section {
            Label("Búsqueda inteligente", systemImage: "magnifyingglass")
                .foregroundStyle(Theme.Text.tertiary)
            Label("Preguntar a Ruul", systemImage: "sparkles")
                .foregroundStyle(Theme.Text.tertiary)
            Label("Escanear QR", systemImage: "qrcode.viewfinder")
                .foregroundStyle(Theme.Text.tertiary)
        } header: {
            Text("Próximamente")
        } footer: {
            Text("Pronto podrás buscar entre todos tus espacios, preguntar cualquier cosa a Ruul y escanear códigos para unirte rápido.")
        }
        .disabled(true)
    }
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
