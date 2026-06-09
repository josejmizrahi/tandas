import SwiftUI
import RuulCore

/// R.2R — detalle de una obligación universal (money / action / approval / …).
/// Renderiza title/description/status + botones de acción canónicos del backend.
/// El frontend NO computa permisos: lee `availableActions[]` del detalle.
public struct ObligationDetailView: View {
    let obligationId: UUID
    let context: AppContext
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var detail: ObligationDetail?
    @State private var phase: StorePhase = .idle
    @State private var runner = ActionRunner()
    @State private var completionNotes: String = ""
    @State private var isShowingCompleteSheet = false
    @State private var memberNamesById: [UUID: String] = [:]
    /// R.2S.10 — sheet "¿Por qué este compromiso?" con why_obligation_exists.
    @State private var why: WhyObligationExists?
    @State private var isLoadingWhy = false
    /// F.MONEY.4 — sheet de edición de la obligación.
    @State private var isShowingEdit = false
    /// R.5W.P1 — alert "Próximamente" para acciones backend-advertised pero sin
    /// RPC iOS todavía (pay/dispute/forgive/cancel). Antes eran Label inerte.
    @State private var comingSoonAction: ComingSoonAction?

    public init(obligationId: UUID, context: AppContext, container: DependencyContainer) {
        self.obligationId = obligationId
        self.context = context
        self.container = container
    }

    private var rpc: any RuulRPCClient { container.rpc }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Compromiso")
                .navigationBarTitleDisplayMode(.inline)
                // R.5V.X 2026-06-08 founder option B — acciones del compromiso
                // viven en el "+" Menu del toolbar (Apple Wallet pattern).
                // El body solo describe; el toolbar acciona.
                .toolbar {
                    if let detail {
                        let actions = detail.availableActions.inSection("obligations")
                            .filter { $0.enabled }
                        if !actions.isEmpty {
                            ToolbarItem(placement: .topBarTrailing) {
                                actionsToolbarMenu(actions: actions)
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Listo") { dismiss() }
                    }
                }
                .task {
                    await load()
                    await container.subscriptionsStore.load()
                }
                .actionErrorAlert(runner)
                .sheet(isPresented: $isShowingCompleteSheet) {
                    completeSheet
                }
                .sheet(item: Binding(get: { why.map { WhyObligationSheetItem(value: $0) } },
                                      set: { why = $0?.value })) { wrapper in
                    WhyObligationSheet(result: wrapper.value)
                }
                // F.MONEY.4 — sheet de edición.
                .sheet(isPresented: $isShowingEdit) {
                    if let detail {
                        EditObligationView(
                            detail: detail,
                            container: container,
                            onSaved: { Task { await load() } }
                        )
                    }
                }
                // R.5W.P1 — alert canónico "Próximamente" (copy founder-signed
                // R.5X.fix.A, reutilizado aquí porque sin RPC iOS no hay donde
                // navegar todavía).
                .alert(
                    comingSoonAction?.label ?? "",
                    isPresented: Binding(
                        get: { comingSoonAction != nil },
                        set: { if !$0 { comingSoonAction = nil } }
                    ),
                    presenting: comingSoonAction
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { _ in
                    Text("Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            LoadingStateView()
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await load() }
            }
        case .loaded:
            if let detail {
                detailList(detail)
            } else {
                ErrorStateView(message: "No se pudo cargar el compromiso.")
            }
        }
    }

    @ViewBuilder
    private func detailList(_ detail: ObligationDetail) -> some View {
        // R.5V.X 2026-06-08 — Apple-native canonical Detail pattern (V.4/V.5).
        List {
            // Hero
            Section {
                HStack(spacing: 14) {
                    Image(systemName: kindSymbol(detail.kind))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Tint.primary)
                        .frame(width: 56, height: 56)
                        .background(Theme.Tint.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.title?.isEmpty == false ? detail.title! : kindLabel(detail.kind))
                            .font(.title3.bold())
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(2)
                        Text(kindLabel(detail.kind))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(statusLabel(detail.status))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor(detail.status))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))

                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Theme.Text.primary)
                }
            }

            SubscribeSection(
                targetType: .obligation,
                targetId: obligationId,
                store: container.subscriptionsStore
            )

            Section {
                LabeledContent("Deudor", value: memberNamesById[detail.debtorActorId] ?? "—")
                LabeledContent("Acreedor", value: memberNamesById[detail.creditorActorId] ?? "—")
                if let dueAt = detail.dueAt {
                    LabeledContent(
                        "Vence",
                        value: dueAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                // F.2X.5 — sin branch por `detail.kind == "money"`. La invariante
                // backend es que `amount` sólo existe en obligaciones monetarias.
                if let amount = detail.amount {
                    LabeledContent("Monto", value: amount.currencyLabel(detail.currency))
                }
            } header: {
                Text("Partes")
            }

            if let completed = detail.completedAt {
                Section {
                    LabeledContent(
                        "Cumplida",
                        value: completed.formatted(date: .abbreviated, time: .shortened)
                    )
                    if let byId = detail.completedByActorId {
                        LabeledContent("Por", value: memberNamesById[byId] ?? "—")
                    }
                    if let notes = detail.completionNotes, !notes.isEmpty {
                        Text(notes)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                    }
                } header: {
                    Text("Cumplimiento")
                }
            }

            // R.5V.X 2026-06-08 — acciones movidas al "+" Menu del toolbar
            // (founder option B, Apple Wallet pattern). El body solo describe.

            // R.2S.10 — ¿Por qué este compromiso?
            Section {
                Button {
                    Task { await loadWhy() }
                } label: {
                    Label("¿Por qué este compromiso?", systemImage: "questionmark.circle")
                }
                .disabled(isLoadingWhy)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func loadWhy() async {
        isLoadingWhy = true
        defer { isLoadingWhy = false }
        do {
            why = try await rpc.whyObligationExists(obligationId: obligationId)
        } catch {
            why = nil
        }
    }

    /// R.5V.X 2026-06-08 — Toolbar Menu con todas las acciones del compromiso.
    /// Reemplaza el Section "Acciones" inline. Patrón Apple Wallet/Stocks.
    @ViewBuilder
    private func actionsToolbarMenu(actions: [AvailableAction]) -> some View {
        Menu {
            ForEach(actions) { action in
                let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
                let isDangerous = action.actionKey == "cancel" || action.actionKey == "dispute" || action.actionKey == "forgive"
                Button(role: isDangerous ? .destructive : nil) {
                    handleObligationAction(action)
                } label: {
                    Label(action.label, systemImage: presentation.symbolName)
                }
                .disabled(!action.enabled || runner.isRunning)
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
        .accessibilityLabel("Acciones del compromiso")
    }

    /// Dispatch routing — antes vivía en actionRow inline, ahora compartido
    /// por el toolbar Menu.
    private func handleObligationAction(_ action: AvailableAction) {
        switch action.actionKey {
        case "mark_completed":
            completionNotes = ""
            isShowingCompleteSheet = true
        case "edit_obligation":
            isShowingEdit = true
        default:
            // pay/dispute/forgive/cancel — backend-advertised pero sin RPC iOS.
            comingSoonAction = ComingSoonAction(key: action.actionKey, label: action.label)
        }
    }

    @ViewBuilder
    private var completeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notas (opcional)", text: $completionNotes, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("¿Cómo lo cumpliste?")
                } footer: {
                    Text("Las notas quedan visibles para deudor, acreedor y administradores.")
                }
            }
            .navigationTitle("Marcar cumplida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { isShowingCompleteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cumplir") {
                        Task { await complete() }
                    }
                    .disabled(runner.isRunning)
                }
            }
            .actionErrorAlert(runner)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        if detail == nil { phase = .loading }
        do {
            async let detailTask = rpc.obligationDetail(obligationId: obligationId)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loadedDetail, summary) = try await (detailTask, summaryTask)
            detail = loadedDetail
            memberNamesById = Dictionary(uniqueKeysWithValues: summary.members.map { ($0.actorId, $0.displayName) })
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    private func complete() async {
        let trimmed = completionNotes.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            _ = try await rpc.completeObligation(
                obligationId: obligationId,
                completionNotes: trimmed.isEmpty ? nil : trimmed,
                completionMetadata: nil
            )
        }
        if success {
            isShowingCompleteSheet = false
            await load()
        }
    }

    private func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "money": return "banknote.fill"
        case "action": return "checkmark.circle"
        case "approval": return "checkmark.seal"
        case "delivery": return "shippingbox"
        case "attendance": return "person.crop.circle.badge.checkmark"
        case "document": return "doc.text"
        case "reservation": return "calendar.badge.clock"
        default: return "circle.dashed"
        }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "money": return "Dinero"
        case "action": return "Acción"
        case "approval": return "Aprobación"
        case "delivery": return "Entrega"
        case "attendance": return "Asistencia"
        case "document": return "Documento"
        case "reservation": return "Reservación"
        case "custom": return "Otro"
        default: return kind
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "open": return "Abierta"
        case "accepted": return "Aceptada"
        case "in_progress": return "En progreso"
        case "completed": return "Cumplida"
        case "expired": return "Vencida"
        case "settled": return "Liquidada"
        case "forgiven": return "Perdonada"
        case "disputed": return "En disputa"
        case "cancelled": return "Cancelada"
        default: return status
        }
    }

    private func statusColor(_ status: String) -> Color {
        Theme.Status.obligation(status)
    }

}

// MARK: - R.5W.P1 Próximamente alert

private struct ComingSoonAction: Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

// MARK: - R.2S.10 ¿Por qué? sheet

private struct WhyObligationSheetItem: Identifiable {
    let value: WhyObligationExists
    var id: UUID { value.obligationId }
}

private struct WhyObligationSheet: View {
    let result: WhyObligationExists
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: sourceSymbol(result.source))
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(sourceLabel(result.source))
                                .font(.callout.weight(.semibold))
                            Text(result.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let ruleTitle = result.ruleTitle, !ruleTitle.isEmpty {
                    Section("Regla") {
                        Label(ruleTitle, systemImage: "wand.and.rays")
                    }
                }
            }
            .navigationTitle("¿Por qué?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "rule": return "Generada por una regla"
        case "decision": return "Resultado de una decisión"
        case "event": return "Ligada a un evento"
        case "reservation": return "Ligada a una reservación"
        case "manual": return "Creada manualmente"
        default: return source
        }
    }

    private func sourceSymbol(_ source: String) -> String {
        switch source {
        case "rule": return "wand.and.rays"
        case "decision": return "checkmark.seal.fill"
        case "event": return "calendar"
        case "reservation": return "calendar.badge.clock"
        case "manual": return "hand.raised"
        default: return "questionmark.circle"
        }
    }
}
