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
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
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
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: kindSymbol(detail.kind))
                        .foregroundStyle(.tint)
                        .font(.title2)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = detail.title, !title.isEmpty {
                            Text(title).font(.headline)
                        } else {
                            Text(kindLabel(detail.kind)).font(.headline)
                        }
                        Text(kindLabel(detail.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(statusLabel(detail.status), color: statusColor(detail.status))
                }

                if let description = detail.description, !description.isEmpty {
                    Text(description).font(.callout)
                }
            }

            SubscribeSection(
                targetType: .obligation,
                targetId: obligationId,
                store: container.subscriptionsStore
            )

            Section("Partes") {
                InfoRow(
                    symbolName: "person.fill",
                    title: "Deudor",
                    value: memberNamesById[detail.debtorActorId] ?? "—"
                )
                InfoRow(
                    symbolName: "person",
                    title: "Acreedor",
                    value: memberNamesById[detail.creditorActorId] ?? "—"
                )
                if let dueAt = detail.dueAt {
                    InfoRow(
                        symbolName: "calendar.badge.clock",
                        title: "Vence",
                        value: dueAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                // F.2X.5 — sin branch por `detail.kind == "money"`. La invariante
                // backend es que `amount` sólo existe en obligaciones monetarias;
                // mostrar el row si está presente es equivalente y respeta doctrina
                // intent-first (no decidir UI por tipo de primitiva).
                if let amount = detail.amount {
                    InfoRow(
                        symbolName: "banknote",
                        title: "Monto",
                        value: amount.currencyLabel(detail.currency)
                    )
                }
            }

            if let completed = detail.completedAt {
                Section("Cumplimiento") {
                    InfoRow(
                        symbolName: "checkmark.seal.fill",
                        title: "Cumplida",
                        value: completed.formatted(date: .abbreviated, time: .shortened)
                    )
                    if let byId = detail.completedByActorId {
                        InfoRow(
                            symbolName: "person.crop.circle.badge.checkmark",
                            title: "Por",
                            value: memberNamesById[byId] ?? "—"
                        )
                    }
                    if let notes = detail.completionNotes, !notes.isEmpty {
                        Text(notes).font(.callout)
                    }
                }
            }

            // R.2S — botones gateados por backend (forma canónica 7 campos).
            let actions = detail.availableActions.inSection("obligations")
            if !actions.isEmpty {
                Section("Acciones") {
                    ForEach(actions) { action in
                        actionRow(action, detail: detail)
                    }
                }
            }

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

    @ViewBuilder
    private func actionRow(_ action: AvailableAction, detail: ObligationDetail) -> some View {
        switch action.actionKey {
        case "mark_completed":
            Button {
                completionNotes = ""
                isShowingCompleteSheet = true
            } label: {
                Label(action.label, systemImage: "checkmark.circle.fill")
            }
            .disabled(!action.enabled || runner.isRunning)
        default:
            // Affordance read-only (pay/dispute/forgive/cancel se cablean cuando exista UI).
            HStack {
                Label(action.label, systemImage: actionSymbol(action.actionKey))
                Spacer()
                if !action.enabled {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .foregroundStyle(action.enabled ? .primary : .secondary)
            .accessibilityHint(action.reason ?? "")
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

    private func actionSymbol(_ key: String) -> String {
        switch key {
        case "pay": return "creditcard.fill"
        case "dispute": return "exclamationmark.bubble"
        case "forgive": return "heart"
        case "cancel": return "xmark.circle"
        default: return "circle"
        }
    }
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
