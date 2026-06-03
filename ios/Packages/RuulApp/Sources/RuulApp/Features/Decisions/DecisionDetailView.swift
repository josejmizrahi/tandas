import SwiftUI
import RuulCore

/// F.10 — detalle de una decisión: votar, ver el conteo, cerrar y ejecutar.
public struct DecisionDetailView: View {
    let decisionId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DecisionDetailStore
    @State private var runner = ActionRunner()
    @State private var isConfirmingClose = false
    @State private var isConfirmingExecute = false
    /// R.2S.10 — sheet "¿Por qué este resultado?" con `why_decision_result`.
    @State private var whyResult: WhyDecisionResult?
    @State private var isLoadingWhy = false

    public init(decisionId: UUID, context: AppContext, container: DependencyContainer) {
        self.decisionId = decisionId
        self.context = context
        self.container = container
        _store = State(initialValue: DecisionDetailStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(decisionId: decisionId, context: context) }
                }

            case .loaded:
                if let decision = store.decision {
                    detailList(decision)
                } else {
                    ErrorStateView(message: "Esta decisión ya no existe o no la puedes ver.")
                }
            }
        }
        .navigationTitle("Decisión")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load(decisionId: decisionId, context: context)
        }
        .refreshable {
            await store.load(decisionId: decisionId, context: context)
        }
        .actionErrorAlert(runner)
    }

    @ViewBuilder
    private func detailList(_ decision: Decision) -> some View {
        List {
            // Header
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(decision.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        StatusBadge(decision.statusLabel, color: statusColor(decision.status))
                        Text(decision.type.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if let description = decision.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                }

                InfoRow(
                    symbolName: "person",
                    title: "Propuesta por",
                    value: store.displayName(for: decision.createdByActorId)
                )
                if let created = decision.createdAt {
                    InfoRow(symbolName: "calendar", title: "Fecha", value: created.formatted(date: .abbreviated, time: .shortened))
                }
            }

            // Ganadora (post-cierre)
            if let winner = store.winningOption(), !decision.isOpen {
                winnerSection(winner)
            }

            // R.2S.10 — "¿Por qué este resultado?" sheet via why_decision_result.
            // Solo aparece cuando la decisión ya no está abierta.
            if !decision.isOpen {
                whySection(decisionId: decisionId)
            }

            // Votos
            votesSection(decision)

            // VoteButtons (yes_no_abstain) o filas de opciones (single_choice).
            // R.2S: gateado por `available_actions` del backend, no por roles locales.
            if decision.isOpen, store.canDo("vote") || store.canDo("change_vote") {
                switch decision.voting {
                case .singleChoice:
                    optionsSection(decision)
                case .yesNoAbstain:
                    voteButtonsSection(decision)
                default:
                    unsupportedVotingModelSection(decision)
                }
            }

            // Cerrar / Ejecutar
            adminSection(decision)
        }
        .confirmationDialog("¿Cerrar la votación?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Cerrar votación") {
                Task {
                    await runner.run {
                        _ = try await store.close(decisionId: decisionId, context: context)
                    }
                }
            }
            Button("Seguir votando", role: .cancel) {}
        }
        .confirmationDialog("¿Ejecutar la decisión?", isPresented: $isConfirmingExecute, titleVisibility: .visible) {
            Button("Ejecutar") {
                Task {
                    await runner.run {
                        try await store.execute(decisionId: decisionId, context: context)
                    }
                }
            }
            Button("Todavía no", role: .cancel) {}
        }
        .sheet(item: Binding(get: { whyResult.map { WhyResultIdentifiable(value: $0) } },
                              set: { whyResult = $0?.value })) { wrapper in
            WhyDecisionResultSheet(result: wrapper.value)
        }
    }

    // MARK: Votos

    @ViewBuilder
    private func votesSection(_ decision: Decision) -> some View {
        let totalMembers = max(store.members.count, 1)
        let missing = max(0, totalMembers - store.votes.count)

        Section("Votos (\(store.votes.count) de \(totalMembers))") {
            switch decision.voting {
            case .singleChoice:
                HStack(spacing: 16) {
                    voteCounter("Votos", count: store.votes.count, color: .accentColor)
                    voteCounter("Faltan", count: missing, color: .gray)
                }
                .padding(.vertical, 4)
            default:
                let approveCount = store.votes.filter { $0.vote == "approve" }.count
                let rejectCount = store.votes.filter { $0.vote == "reject" }.count
                HStack(spacing: 16) {
                    voteCounter("A favor", count: approveCount, color: .green)
                    voteCounter("En contra", count: rejectCount, color: .red)
                    voteCounter("Faltan", count: missing, color: .gray)
                }
                .padding(.vertical, 4)
            }

            ForEach(store.votes) { vote in
                voteRow(vote, decision: decision)
            }
        }
    }

    @ViewBuilder
    private func voteRow(_ vote: DecisionVote, decision: Decision) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: store.displayName(for: vote.voterActorId), size: 30)
            Text(store.displayName(for: vote.voterActorId))
            Spacer()
            switch decision.voting {
            case .singleChoice:
                if let optionId = vote.optionId,
                   let option = store.options.first(where: { $0.id == optionId }) {
                    StatusBadge(option.title, color: .accentColor)
                } else if vote.vote == "abstain" {
                    StatusBadge("Abstención", color: .gray)
                } else {
                    StatusBadge("Sin opción", color: .gray)
                }
            default:
                StatusBadge(
                    vote.choice?.label ?? vote.vote,
                    color: vote.vote == "approve" ? .green : (vote.vote == "reject" ? .red : .gray)
                )
            }
        }
    }

    @ViewBuilder
    private func voteCounter(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: VoteButtons

    @ViewBuilder
    private func voteButtonsSection(_ decision: Decision) -> some View {
        let mine = store.myVote(myActorId: myActorId)

        Section {
            HStack(spacing: 12) {
                voteButton("A favor", choice: .approve, isCurrent: mine?.vote == "approve", color: .green)
                voteButton("En contra", choice: .reject, isCurrent: mine?.vote == "reject", color: .red)
                voteButton("Abstención", choice: .abstain, isCurrent: mine?.vote == "abstain", color: .gray)
            }
            .buttonStyle(.borderless)
        } header: {
            Text(mine == nil ? "Tu voto" : "Cambiar tu voto")
        } footer: {
            Text("Se aprueba automáticamente cuando más de la mitad de los miembros vota a favor.")
        }
    }

    // MARK: Opciones (single_choice — R.2Q)

    @ViewBuilder
    private func optionsSection(_ decision: Decision) -> some View {
        let mine = store.myVote(myActorId: myActorId)
        let myOptionId = mine?.optionId

        Section {
            ForEach(store.options) { option in
                optionRow(option, isCurrent: option.id == myOptionId, decision: decision)
            }
        } header: {
            Text(mine == nil ? "Elige una opción" : "Cambia tu voto")
        } footer: {
            Text("Gana la opción con más votos cuando supere la mitad de los miembros o cuando todos voten.")
        }
    }

    @ViewBuilder
    private func optionRow(_ option: DecisionOption, isCurrent: Bool, decision: Decision) -> some View {
        Button {
            Task {
                await runner.run {
                    _ = try await store.vote(for: option, decisionId: decisionId, context: context)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                let count = store.voteCount(for: option)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning)
    }

    // MARK: ¿Por qué? (R.2S.10)

    @ViewBuilder
    private func whySection(decisionId: UUID) -> some View {
        Section {
            Button {
                Task { await loadWhy(decisionId: decisionId) }
            } label: {
                Label("¿Por qué este resultado?", systemImage: "questionmark.circle")
            }
            .disabled(isLoadingWhy)
        }
    }

    private func loadWhy(decisionId: UUID) async {
        isLoadingWhy = true
        defer { isLoadingWhy = false }
        do {
            whyResult = try await container.rpc.whyDecisionResult(decisionId: decisionId)
        } catch {
            // Si falla, no rompemos la vista — el sheet simplemente no se abre.
            whyResult = nil
        }
    }

    // MARK: Ganadora

    @ViewBuilder
    private func winnerSection(_ winner: DecisionOption) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ganadora")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(winner.title)
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func unsupportedVotingModelSection(_ decision: Decision) -> some View {
        Section {
            Label("Modo de votación no disponible todavía", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        } footer: {
            Text("\(decision.voting.label) llega en una próxima versión.")
        }
    }

    @ViewBuilder
    private func voteButton(_ label: String, choice: VoteChoice, isCurrent: Bool, color: Color) -> some View {
        Button {
            Task {
                await runner.run {
                    _ = try await store.vote(choice, decisionId: decisionId, context: context)
                }
            }
        } label: {
            Text(label)
                .font(.callout.weight(isCurrent ? .bold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    isCurrent ? color.opacity(0.25) : Color(uiColor: .tertiarySystemFill),
                    in: Capsule()
                )
                .foregroundStyle(isCurrent ? color : .primary)
        }
        .disabled(runner.isRunning)
    }

    // MARK: Cerrar / Ejecutar

    @ViewBuilder
    private func adminSection(_ decision: Decision) -> some View {
        // R.2S: cada botón aparece SOLO si el backend lo trae habilitado.
        if let action = store.availableAction("close_decision") {
            Section {
                Button {
                    isConfirmingClose = true
                } label: {
                    Label(action.label, systemImage: "stop.circle")
                }
                .disabled(runner.isRunning)
            } footer: {
                Text(action.reason ?? "Cierra la votación con los votos actuales.")
            }
        }

        if let action = store.availableAction("execute_decision") {
            Section {
                Button {
                    isConfirmingExecute = true
                } label: {
                    Label(action.label, systemImage: "play.circle.fill")
                }
                .disabled(runner.isRunning)
            } footer: {
                Text(action.reason ?? "Marca la decisión como ejecutada.")
            }
        }

        if decision.isExecuted {
            Section {
                Label("Esta decisión ya fue ejecutada", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "open": return .blue
        case "approved": return .green
        case "rejected": return .red
        case "executed": return .purple
        case "cancelled": return .gray
        default: return .secondary
        }
    }
}

// MARK: - WhyDecisionResult sheet (R.2S.10)

/// Wrapper Identifiable para `.sheet(item:)`.
private struct WhyResultIdentifiable: Identifiable {
    let value: WhyDecisionResult
    var id: UUID { value.decisionId }
}

/// Sheet que renderiza la razón del resultado de la decisión — sin computar
/// nada en iOS, todo viene del backend.
private struct WhyDecisionResultSheet: View {
    let result: WhyDecisionResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.purple)
                        Text("Estado: \(result.status)")
                            .font(.callout.weight(.semibold))
                    }
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.secondary)
                        Text("Modelo: \(result.votingModel)")
                            .font(.callout)
                    }
                }

                Section("Conteo") {
                    HStack(spacing: 16) {
                        tallyCounter("A favor", count: result.tally.approve, color: .green)
                        tallyCounter("En contra", count: result.tally.reject, color: .red)
                        tallyCounter("Abstención", count: result.tally.abstain, color: .gray)
                        tallyCounter("Miembros", count: result.activeMembers, color: .secondary)
                    }
                    .padding(.vertical, 4)
                }

                if !result.optionTally.isEmpty {
                    Section("Opciones") {
                        ForEach(result.optionTally.sorted(by: { $0.value > $1.value }), id: \.key) { option, count in
                            HStack {
                                Text(option)
                                Spacer()
                                Text("\(Int(count)) voto\(count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Razones") {
                    ForEach(result.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.callout)
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
    }

    @ViewBuilder
    private func tallyCounter(_ label: String, count: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(count))")
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Detalle de decisión") {
    NavigationStack {
        DecisionDetailPreviewWrapper()
    }
}

private struct DecisionDetailPreviewWrapper: View {
    @State private var decisionId: UUID?
    private let container = DependencyContainer.demo()
    private let context = AppContext(
        id: MockRuulRPCClient.DemoIds.familia,
        kind: .collective,
        subtype: "family",
        displayName: "Familia Mizrahi",
        roles: ["admin"]
    )

    var body: some View {
        Group {
            if let decisionId {
                DecisionDetailView(decisionId: decisionId, context: context, container: container)
            } else {
                ProgressView()
            }
        }
        .task {
            // Crear una decisión demo para el preview.
            let decision = try? await container.rpc.createDecision(CreateDecisionInput(
                contextId: context.id,
                decisionType: .reservationDispute,
                title: "¿Quién se queda con Casa Valle este fin?",
                description: "David e Isaac pidieron las mismas fechas."
            ))
            decisionId = decision?.id
        }
    }
}
