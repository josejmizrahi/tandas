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
    /// R.7.x — confirmación destructive del forgive directo (no-governance path).
    @State private var isConfirmingForgive = false
    /// R.7.x — sheet "Esta acción requiere aprobación" para forgive con governance.
    /// El descriptor `availableActions` puede traer `mode=request_decision` cuando
    /// el catálogo o la policy del contexto exigen votación. Sino, el backend igual
    /// gatea con `governance_required` (42501) y caemos al governance flow.
    @State private var isShowingGovernanceSheet = false
    @State private var governanceClientId: String = UUID().uuidString
    @State private var pendingDecisionId: UUID?

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
                        // R.13.B (founder lock 2026-06-16) — gating defensivo via
                        // whitelist global `ActionRouter.knownActionKeys`. iOS NO
                        // muestra button para action_key sin handler local.
                        // Doctrina "nada que no tenga que estar" reemplaza
                        // R.5X.fix.A "Próximamente" copy — esconder en vez de
                        // mostrar honestidad falsa.
                        let actions = detail.availableActions.inSection("obligations")
                            .filter { $0.enabled && ActionRouter.isWired($0.actionKey) }
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
                // R.7.x — confirm direct forgive (no-governance path).
                .confirmationDialog(
                    "¿Condonar este compromiso?",
                    isPresented: $isConfirmingForgive,
                    titleVisibility: .visible
                ) {
                    Button("Condonar", role: .destructive) {
                        Task { await forgiveDirect() }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("El compromiso queda perdonado. No afecta el balance del grupo.")
                }
                // R.7.x — governance sheet (requires_decision path).
                .confirmationDialog(
                    "Esta acción requiere aprobación",
                    isPresented: $isShowingGovernanceSheet,
                    titleVisibility: .visible
                ) {
                    Button("Crear votación") {
                        Task { await requestGovernanceForgive() }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("Condonar este compromiso requiere aprobación del grupo. Se creará una votación para que los miembros aprueben.")
                }
                // R.7.x — push DecisionDetailView cuando request_governance_action devuelve decision_id.
                .sheet(item: Binding(
                    get: { pendingDecisionId.map { DecisionIdSheetWrapper(id: $0) } },
                    set: { pendingDecisionId = $0?.id }
                ), onDismiss: {
                    Task { await load() }
                }) { wrapper in
                    NavigationStack {
                        DecisionDetailView(decisionId: wrapper.id, context: context, container: container)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            RuulLoadingState()
        case .failed(let message):
            RuulErrorState(message: message) {
                Task { await load() }
            }
        case .loaded:
            if let detail {
                detailList(detail)
            } else {
                RuulErrorState(message: "No se pudo cargar el compromiso.")
            }
        }
    }

    @ViewBuilder
    private func detailList(_ detail: ObligationDetail) -> some View {
        // R.5V.X 2026-06-08 — Apple-native canonical Detail pattern (V.4/V.5).
        // R.10.H (2026-06-15) — Hero migra a RuulDetailHero canonical
        // (consistente con EventDetail / DocumentDetail / DecisionDetail).
        // Status como RuulStatusBadge canonical en vez de Text estilizado.
        List {
            Section {
                RuulDetailHero(
                    title: heroTitle(detail),
                    subtitle: heroSubtitle(detail),
                    systemImage: kindSymbol(detail.kind),
                    tint: Theme.Tint.primary,
                    status: RuulStatusBadge.State.obligation(detail.status)
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let description = detail.description, !description.isEmpty {
                Section {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Theme.Text.primary)
                } header: {
                    Text("Descripción")
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

            if shouldShowSettlePath(detail) {
                settlePathSection
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

    /// FE.2 (doctrina founder 2026-06-11) — el pago de obligaciones money fluye
    /// por el settlement canónico (`generate_settlement_batch` +
    /// `mark_settlement_paid`); un `pay_obligation` directo duplicaría esa vía.
    /// Mostramos la ruta canónica desde el detalle cuando el caller es el deudor
    /// de una obligación money activa, para que no quede confundido buscando un
    /// botón "Pagar" inexistente.
    private func shouldShowSettlePath(_ detail: ObligationDetail) -> Bool {
        guard detail.kind == "money" else { return false }
        guard ["open", "accepted", "in_progress"].contains(detail.status) else { return false }
        guard let me = container.currentActorStore.actorId else { return false }
        return me == detail.debtorActorId
    }

    @ViewBuilder
    private var settlePathSection: some View {
        Section {
            Label {
                Text("Esta deuda se salda en el neteo del grupo. Liquidaciones suma todo lo que debes a cada miembro y lo cierra junto.")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
            } icon: {
                Image(systemName: "scalemass")
                    .foregroundStyle(Theme.Tint.info)
            }
            Button {
                dismiss()
            } label: {
                Label("Ir a Dinero", systemImage: "arrow.right.circle.fill")
            }
        } header: {
            Text("¿Cómo se salda?")
        } footer: {
            Text("Pronto vas a poder iniciar el neteo desde aquí mismo.")
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

    /// R.5V.X 2026-06-08 — Toolbar Menu con todas las acciones del compromiso.
    /// Reemplaza el Section "Acciones" inline. Patrón Apple Wallet/Stocks.
    @ViewBuilder
    private func actionsToolbarMenu(actions: [AvailableAction]) -> some View {
        Menu {
            ForEach(actions) { action in
                // P0.5 — componente canónico: muestra el reason cuando la acción
                // está deshabilitada (antes se ocultaba). `runner.isRunning` la
                // bloquea mientras corre otra acción.
                ActionMenuButton.deriving(action: action, extraDisabled: runner.isRunning) {
                    handleObligationAction(action)
                }
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
        // F.2X — el mapeo key→destino vive en ActionRouter; aquí sólo se
        // decide el flow local (sheet / governance / coming soon).
        switch ActionRouter.quickActionDestination(for: action.actionKey) {
        case .markObligationCompleted:
            completionNotes = ""
            isShowingCompleteSheet = true
        case .editObligation:
            isShowingEdit = true
        case .forgiveObligation:
            // R.7.x — branch governance ↔ direct según `mode` del descriptor.
            // Si el descriptor todavía no surface `mode` (default nil → direct),
            // el confirm directo dispara la RPC y el backend devuelve
            // `governance_required` 42501 si la policy lo exige.
            if action.requiresDecision {
                governanceClientId = UUID().uuidString
                isShowingGovernanceSheet = true
            } else {
                isConfirmingForgive = true
            }
        default:
            // R.13.B — inalcanzable post-gating. El filtro `ActionRouter.isWired`
            // del toolbar excluye action_keys sin handler. Si llega aquí algo
            // significa que la whitelist y este switch están desincronizados.
            assertionFailure("Unwired obligation action reached handler: \(action.actionKey)")
        }
    }

    /// R.7.x — direct path. Invoca `forgive_obligation`. Si el backend exige
    /// governance, vendrá 42501 con copy traducido por `RPCErrorMapper`.
    private func forgiveDirect() async {
        let trimmed = nil as String?  // sin razón por ahora — wizard de motivo es R.7.x backlog.
        let success = await runner.run {
            _ = try await rpc.forgiveObligation(obligationId: obligationId, reason: trimmed)
        }
        if success {
            await load()
            await container.attentionInboxStore.load() // D5
        }
    }

    /// R.7.x — governance path. Pide aprobación colectiva con canonical key
    /// `obligation.forgive`. El backend usa idempotency_key sha1 sobre clientId.
    private func requestGovernanceForgive() async {
        let input = RequestGovernanceActionInput(
            contextActorId: context.id,
            actionKey: "obligation.forgive",
            targetType: "obligation",
            targetId: obligationId,
            payload: .object([:]),
            title: forgiveDecisionTitle,
            closesAt: nil,
            clientId: governanceClientId
        )
        var capturedDecisionId: UUID?
        let success = await runner.run {
            let result = try await rpc.requestGovernanceAction(input)
            capturedDecisionId = result.decisionId
        }
        if success, let decisionId = capturedDecisionId {
            pendingDecisionId = decisionId
        }
    }

    private var forgiveDecisionTitle: String {
        let name = detail?.title?.isEmpty == false ? detail!.title! : "compromiso"
        return "Condonar \(name)"
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
            await container.attentionInboxStore.load() // D5
        }
    }

    /// R.10.H — heroTitle: la title custom si existe, sino el kind label como fallback.
    private func heroTitle(_ detail: ObligationDetail) -> String {
        if let title = detail.title, !title.isEmpty {
            return title
        }
        return kindLabel(detail.kind)
    }

    /// R.10.H — heroSubtitle: solo cuando hay title custom (sino el kind ya es
    /// el title y no hay nada que repetir).
    private func heroSubtitle(_ detail: ObligationDetail) -> String? {
        guard let title = detail.title, !title.isEmpty else { return nil }
        return kindLabel(detail.kind)
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

    // R.10.H — statusLabel/statusColor eliminados. RuulStatusBadge.State.obligation
    // ya cubre el mapeo canónico de status → label + tint.

}

/// R.7.x — wrapper Identifiable para presentar `DecisionDetailView` via `.sheet(item:)`.
private struct DecisionIdSheetWrapper: Identifiable {
    let id: UUID
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
        case "decision": return "Resultado de una votación"
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

// MARK: - Previews

#Preview("Compromiso — Cena Semanal") {
    NavigationStack {
        ObligationDetailPreviewWrapper()
    }
}

/// El preview necesita resolver el id de la obligación demo de forma async
/// (mismo patrón que EventDetailPreviewWrapper).
private struct ObligationDetailPreviewWrapper: View {
    @State private var obligationId: UUID?
    private let container = DependencyContainer.demo()
    private let context = AppContext(
        id: MockRuulRPCClient.DemoIds.cenaSemanal,
        kind: .collective,
        subtype: "friend_group",
        displayName: "Cena Semanal",
        roles: ["admin"]
    )

    var body: some View {
        Group {
            if let obligationId {
                ObligationDetailView(obligationId: obligationId, context: context, container: container)
            } else {
                ProgressView()
            }
        }
        .task {
            let obligations = try? await container.rpc.listObligations(contextId: context.id)
            obligationId = obligations?.first?.id
        }
    }
}
