import SwiftUI
import RuulCore

/// F.DECISION.1 — Decision Detail Question-First.
///
/// El usuario no abre una decisión para administrar metadata: la abre para
/// responder una pregunta importante para su grupo y entender sus
/// consecuencias. La pantalla se siente más cercana a Apple Wallet / Stocks
/// / Reminders que a un sistema parlamentario.
///
/// Jerarquía founder-locked:
/// 1. Hero (icono + pregunta + estado + hint inline)
/// 2. Estado (status + votos pendientes + participación)
/// 3. Tu decisión (cards adaptadas por voting model)
/// 4. Resultados actuales (barras visuales)
/// 5. Participantes (faltantes primero, máx 5 + Ver todos)
/// 6. ¿Qué ocurre si gana? (consecuencia por opción)
/// 7. Actividad reciente (filtrada por decisión)
/// 8. Seguir esta decisión (suscripción)
/// 9. Administración (DisclosureGroup, sólo con autoridad)
/// 10. Auditoría (DisclosureGroup, sólo con autoridad)
///
/// Cero exposición de claves técnicas (`decision.vote_cast`, voting model raw,
/// activity keys). Las acciones admin nacen de `availableActions[]` del backend.
public struct DecisionDetailView: View {
    let decisionId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DecisionDetailStore
    @State private var runner = ActionRunner()
    @State private var isConfirmingClose = false
    @State private var isConfirmingExecute = false
    /// R.5W.P1 — diálogo dedicado para `cancel_decision` (antes reutilizaba
    /// `isConfirmingClose` y mostraba "¿Cerrar la votación?" cuando el botón
    /// era "Cancelar decisión", causando confusión).
    @State private var isConfirmingCancel = false
    @State private var whyResult: WhyDecisionResult?
    @State private var isLoadingWhy = false
    @State private var decisionActivity: [ActivityEvent] = []
    @State private var isShowingAllParticipants = false
    @State private var isShowingFullActivity = false
    /// F.DECISION.5 — sheet de edición de la decisión.
    @State private var isShowingEdit = false

    public init(decisionId: UUID, context: AppContext, container: DependencyContainer) {
        self.decisionId = decisionId
        self.context = context
        self.container = container
        _store = State(initialValue: DecisionDetailStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }

    private var hasManageAuthority: Bool {
        store.canDo("close_decision")
            || store.canDo("execute_decision")
            || store.canDo("cancel_decision")
            || store.canDo("edit_decision")
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()

            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(decisionId: decisionId, context: context) }
                }

            case .loaded:
                if let decision = store.decision {
                    detailList(decision)
                } else {
                    RuulErrorState(message: "Esta decisión ya no existe o no la puedes ver.")
                }
            }
        }
        .navigationTitle(store.decision?.title ?? "Decisión")
        .navigationBarTitleDisplayMode(.inline)
        // P0 fix 2026-06-08 — toolbar Menu mirror de adminSection (Estado /
        // Editar). Acceso rápido desde header sin scroll hasta DisclosureGroup.
        .toolbar {
            let actions = store.decision.map(adminActions) ?? []
            if hasManageAuthority && !actions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        let stateActions = actions.filter { $0.kind != .editDecision }
                        let editActions = actions.filter { $0.kind == .editDecision }
                        if !stateActions.isEmpty {
                            Section("Estado") {
                                ForEach(Array(stateActions.enumerated()), id: \.offset) { _, action in
                                    Button(role: action.role == .destructive ? .destructive : nil) {
                                        handleAdminAction(action)
                                    } label: {
                                        Label(action.label, systemImage: action.symbol)
                                    }
                                    .disabled(!action.enabled || runner.isRunning)
                                }
                            }
                        }
                        if !editActions.isEmpty {
                            Section("Editar") {
                                ForEach(Array(editActions.enumerated()), id: \.offset) { _, action in
                                    Button {
                                        handleAdminAction(action)
                                    } label: {
                                        Label(action.label, systemImage: action.symbol)
                                    }
                                    .disabled(!action.enabled || runner.isRunning)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Acciones de la decisión")
                }
            }
        }
        .task {
            await store.load(decisionId: decisionId, context: context)
            await container.subscriptionsStore.load()
            await loadDecisionActivity()
        }
        .refreshable {
            await store.load(decisionId: decisionId, context: context)
            await container.subscriptionsStore.load()
            await loadDecisionActivity()
        }
        .actionErrorAlert(runner)
        .confirmationDialog("¿Cerrar la votación?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Cerrar votación") {
                Task {
                    await runner.run {
                        _ = try await store.close(decisionId: decisionId, context: context)
                        await loadDecisionActivity()
                        // D5 (re-audit 2026-06-14) — el item decision_vote/governance_pending
                        // queda obsoleto al cerrar; refrescar inbox limpia la UI sin
                        // esperar al próximo reappear.
                        await container.attentionInboxStore.load()
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
                        await loadDecisionActivity()
                        await container.attentionInboxStore.load() // D5
                    }
                }
            }
            Button("Todavía no", role: .cancel) {}
        }
        .confirmationDialog("¿Cancelar la decisión?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("Cancelar decisión", role: .destructive) {
                Task {
                    await runner.run {
                        _ = try await store.close(decisionId: decisionId, context: context)
                        await loadDecisionActivity()
                        await container.attentionInboxStore.load() // D5
                    }
                }
            }
            Button("Volver", role: .cancel) {}
        } message: {
            Text("La votación se cierra sin ejecutar el resultado.")
        }
        .sheet(item: Binding(get: { whyResult.map { WhyResultIdentifiable(value: $0) } },
                              set: { whyResult = $0?.value })) { wrapper in
            WhyDecisionResultSheet(result: wrapper.value)
        }
        .sheet(isPresented: $isShowingAllParticipants) {
            NavigationStack {
                DecisionParticipantsFullView(
                    members: store.members,
                    votes: store.votes,
                    options: store.options,
                    voting: store.decision?.voting ?? .yesNoAbstain,
                    myActorId: myActorId,
                    store: store
                )
            }
        }
        .sheet(isPresented: $isShowingFullActivity) {
            NavigationStack {
                DecisionActivityFullView(
                    events: decisionActivity,
                    store: store,
                    myActorId: myActorId
                )
            }
        }
        // F.DECISION.5 — sheet de edición.
        .sheet(isPresented: $isShowingEdit) {
            if let decision = store.decision {
                EditDecisionView(
                    decision: decision,
                    container: container,
                    onSaved: {
                        Task { await store.load(decisionId: decisionId, context: context) }
                    }
                )
            }
        }
    }

    // R.5V.6 (2026-06-08) — Apple-native List + Section. La Section ES la card.
    // Cero Theme.cardShape() / VStack envueltos / Divider manual. Scroll anchors
    // estables: el contenido no se mueve cuando data async llega.
    @ViewBuilder
    private func detailList(_ decision: Decision) -> some View {
        // Issue 4 founder (audit 2026-06-14) — antes había 10 secciones
        // consecutivas y el usuario tenía que scrollear hasta abajo. Fix
        // quirúrgico (sin tocar founder lock):
        //   1. Activity preview se reduce de 5 a 3 items (~120px menos scroll).
        //   2. `subscribeSectionList` se oculta cuando el usuario ya está
        //      suscrito (estado por default tras crear la decisión).
        //   3. Admin / Audit ya son DisclosureGroup colapsados — OK.
        List {
            heroSection(decision)
            statusSection(decision)
            yourVoteSection(decision)
            resultsSection(decision)
            participantsSection(decision)
            consequencesSection(decision)
            activitySectionList
            subscribeSectionList
            adminSection(decision)
            auditSection(decision)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 1. Hero (pregunta primero)

    @ViewBuilder
    private func heroSection(_ decision: Decision) -> some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 80, height: 80)
                    .background(Color.accentColor.badgeFill, in: Circle())

                Text(decision.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let description = decision.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    heroChip(
                        symbol: statusSymbol(decision.status),
                        text: decision.statusLabel,
                        tint: statusColor(decision.status)
                    )
                    // P1.7 — countdown reactivo al cierre (Text relativo se
                    // auto-actualiza) + participación visible antes de votar.
                    if decision.isOpen, let closesAt = decision.closesAt {
                        countdownChip(closesAt: closesAt)
                    }
                    if let hint = heroHint(decision) {
                        heroChip(symbol: hint.symbol, text: hint.text, tint: hint.tint)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
        }
    }

    @ViewBuilder
    private func heroChip(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.badgeFillSubtle, in: Capsule())
    }

    /// P1.7 — chip con cuenta regresiva viva al cierre. `Text(_:style:.relative)`
    /// se auto-actualiza cada segundo sin timers manuales.
    @ViewBuilder
    private func countdownChip(closesAt: Date) -> some View {
        let expired = closesAt <= Date()
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption.weight(.semibold))
            if expired {
                Text("Cierre vencido")
                    .font(.caption.weight(.semibold))
            } else {
                (Text("Cierra en ") + Text(closesAt, style: .relative))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.badgeFillSubtle, in: Capsule())
    }

    private func heroHint(_ decision: Decision) -> (text: String, symbol: String, tint: Color)? {
        guard decision.isOpen else { return nil }
        // P1.7 — participación explícita: cuántos han votado del total.
        let total = store.members.count
        let voted = store.votes.count
        if total > 0 {
            return (
                text: "\(voted) de \(total) \(total == 1 ? "voto" : "votos")",
                symbol: "person.badge.clock",
                tint: voted < total ? .blue : .green
            )
        }
        return nil
    }

    // MARK: - 2. Estado

    @ViewBuilder
    private func statusSection(_ decision: Decision) -> some View {
        let totalMembers = max(store.members.count, 1)
        let voted = store.votes.count
        let participation = Int((Double(voted) / Double(totalMembers) * 100.0).rounded())

        Section {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol(decision.status))
                    .font(.title2)
                    .foregroundStyle(statusColor(decision.status))
                    .frame(width: 44, height: 44)
                    .background(statusColor(decision.status).badgeFillSubtle, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.statusLabel)
                        .font(.title3.weight(.semibold))
                    Text(statusSubtitle(decision))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LabeledContent("Votos") {
                Text("\(voted)/\(store.members.count)")
                    .font(.callout.weight(.semibold))
            }
            LabeledContent("Participación") {
                Text("\(participation)%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            // P1.7 — regla de aprobación explícita ANTES de votar. Lee del
            // payload de la decisión (override) o cae al default canónico
            // ("mayoría simple"). Cero RPC nuevo — todo viene en decision_detail.
            LabeledContent("Se aprueba con") {
                Text(approvalRuleLabel(decision))
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.trailing)
            }

            if !decision.isOpen {
                Button {
                    Task { await loadWhy(decisionId: decisionId) }
                } label: {
                    Label("¿Por qué este resultado?", systemImage: "questionmark.circle")
                }
                .disabled(isLoadingWhy)
            }
        } header: {
            Text("Estado")
        }
    }

    /// P1.7 — copy explícito de la regla de aprobación. El backend trae los
    /// overrides en `decision.payload` (quorum + approval_threshold); si la
    /// decisión los hereda del contexto, caemos al label canónico por
    /// voting_model.
    ///
    /// `quorum` y `approval_threshold` son fracciones `0…1` (catálogo R.4B).
    /// Convertimos a "N de M votos" cuando sabemos `members.count`.
    private func approvalRuleLabel(_ decision: Decision) -> String {
        let total = store.members.count
        let payload = decision.payload
        let quorum = payload?["quorum"]?.numberValue
        let threshold = payload?["approval_threshold"]?.numberValue

        switch decision.voting {
        case .consent:
            return "Sin objeciones (consentimiento)"
        case .singleChoice, .multipleChoice, .rankedChoice, .approvalVote:
            // Para choice-based models el resultado es ganador por mayoría
            // relativa entre opciones. Reportamos el threshold cuando existe.
            if let threshold, total > 0 {
                let needed = Int((Double(total) * threshold).rounded(.up))
                return "\(needed) de \(total) votos"
            }
            return "Más votos que cualquier otra opción"
        case .numericAllocation:
            return "Repartir el presupuesto"
        case .yesNoAbstain:
            if let threshold, total > 0 {
                let needed = Int((Double(total) * threshold).rounded(.up))
                let quorumNote = quorum.map { ", quórum \(Int(($0 * 100).rounded()))%" } ?? ""
                return "\(needed) a favor\(quorumNote)"
            }
            return "Mayoría simple"
        }
    }

    private func statusSubtitle(_ decision: Decision) -> String {
        let totalMembers = max(store.members.count, 1)
        let voted = store.votes.count
        let missing = max(0, totalMembers - voted)
        switch decision.status {
        case "open":
            if missing == 0 { return "Todos ya votaron" }
            return missing == 1 ? "Falta 1 voto" : "Faltan \(missing) votos"
        case "approved":
            return "Aprobada con \(voted) de \(totalMembers) votos"
        case "rejected":
            return "Rechazada con \(voted) de \(totalMembers) votos"
        case "executed":
            return "Ya se aplicó"
        case "cancelled":
            return "La decisión fue cancelada"
        default:
            return ""
        }
    }

    // MARK: - 3. Tu decisión

    @ViewBuilder
    private func yourVoteSection(_ decision: Decision) -> some View {
        let canVote = decision.isOpen && (store.canDo("vote") || store.canDo("change_vote"))
        if canVote {
            Section {
                switch decision.voting {
                case .singleChoice:
                    singleChoiceCards()
                case .yesNoAbstain:
                    yesNoAbstainCards()
                case .multipleChoice:
                    multipleChoiceCards()
                default:
                    unsupportedVoteCard(decision)
                }
            } header: {
                Text("Tu decisión")
            } footer: {
                if let mine = store.myVote(myActorId: myActorId) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        Text(yourVoteConfirmation(decision: decision, mine: mine))
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func singleChoiceCards() -> some View {
        let mine = store.myVote(myActorId: myActorId)
        ForEach(store.options) { option in
            voteRow(
                title: option.title,
                description: option.description,
                isCurrent: mine?.optionId == option.id
            ) {
                Task {
                    await runner.run {
                        _ = try await store.vote(for: option, decisionId: decisionId, context: context)
                        await loadDecisionActivity()
                        await container.attentionInboxStore.load() // D5
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func yesNoAbstainCards() -> some View {
        let mine = store.myVote(myActorId: myActorId)
        voteRow(title: "Sí", description: nil, isCurrent: mine?.vote == "approve") {
            Task { await castSimpleVote(.approve) }
        }
        voteRow(title: "No", description: nil, isCurrent: mine?.vote == "reject") {
            Task { await castSimpleVote(.reject) }
        }
        voteRow(title: "Abstenerme", description: nil, isCurrent: mine?.vote == "abstain", muted: true) {
            Task { await castSimpleVote(.abstain) }
        }
    }

    @ViewBuilder
    private func multipleChoiceCards() -> some View {
        let myVotes = Set(store.votes.filter { $0.voterActorId == myActorId }.compactMap { $0.optionId })
        ForEach(store.options) { option in
            voteRow(
                title: option.title,
                description: option.description,
                isCurrent: myVotes.contains(option.id),
                showsCheckmark: true
            ) {
                let alreadySelected = myVotes.contains(option.id)
                Task {
                    await runner.run {
                        if alreadySelected {
                            _ = try await container.rpc.unvoteOption(decisionId: decisionId, optionId: option.id)
                            await store.load(decisionId: decisionId, context: context)
                        } else {
                            _ = try await store.vote(for: option, decisionId: decisionId, context: context)
                        }
                        await loadDecisionActivity()
                        await container.attentionInboxStore.load() // D5
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func unsupportedVoteCard(_ decision: Decision) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Modo de votación no disponible todavía")
                Text("\(decision.voting.label) llega en una próxima versión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func voteRow(
        title: String,
        description: String?,
        isCurrent: Bool,
        showsCheckmark: Bool = false,
        muted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(muted && !isCurrent ? .secondary : .primary)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            } icon: {
                Image(systemName: voteIconName(isCurrent: isCurrent, showsCheckmark: showsCheckmark))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
        }
        .disabled(runner.isRunning)
    }

    private func voteIconName(isCurrent: Bool, showsCheckmark: Bool) -> String {
        if showsCheckmark {
            return isCurrent ? "checkmark.square.fill" : "square"
        }
        return isCurrent ? "largecircle.fill.circle" : "circle"
    }

    private func yourVoteConfirmation(decision: Decision, mine: DecisionVote) -> String {
        switch decision.voting {
        case .singleChoice:
            if let optionId = mine.optionId, let option = store.options.first(where: { $0.id == optionId }) {
                return "Votaste por \(option.title)"
            }
            if mine.vote == "abstain" { return "Te abstuviste" }
            return "Voto registrado"
        case .multipleChoice:
            return "Tus elecciones se guardaron"
        case .yesNoAbstain:
            switch mine.vote {
            case "approve": return "Votaste a favor"
            case "reject":  return "Votaste en contra"
            case "abstain": return "Te abstuviste"
            default:        return "Voto registrado"
            }
        default:
            return "Voto registrado"
        }
    }

    private func castSimpleVote(_ choice: VoteChoice) async {
        await runner.run {
            _ = try await store.vote(choice, decisionId: decisionId, context: context)
            await loadDecisionActivity()
            await container.attentionInboxStore.load() // D5
        }
    }

    // MARK: - 4. Resultados actuales

    @ViewBuilder
    private func resultsSection(_ decision: Decision) -> some View {
        let entries = resultsEntries(decision)
        if !entries.isEmpty, !store.votes.isEmpty {
            let winnerId = winningEntryId(entries: entries, decision: decision)
            Section {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    resultsRow(entry, isWinner: entry.id == winnerId)
                }
            } header: {
                Text("Resultados actuales")
            }
        }
    }

    private struct ResultsEntry {
        let id: String
        let label: String
        let votes: Int
        let total: Int
        var percent: Double { total == 0 ? 0 : Double(votes) / Double(total) }
    }

    private func resultsEntries(_ decision: Decision) -> [ResultsEntry] {
        switch decision.voting {
        case .singleChoice, .multipleChoice:
            let totalVotes = max(store.votes.count, 1)
            let entries = store.options.map { option in
                ResultsEntry(
                    id: option.id.uuidString,
                    label: option.title,
                    votes: store.voteCount(for: option),
                    total: totalVotes
                )
            }
            return entries.sorted { $0.votes > $1.votes }
        case .yesNoAbstain:
            let approve = store.votes.filter { $0.vote == "approve" }.count
            let reject = store.votes.filter { $0.vote == "reject" }.count
            let abstain = store.votes.filter { $0.vote == "abstain" }.count
            let total = max(approve + reject + abstain, 1)
            return [
                ResultsEntry(id: "approve", label: "Sí",         votes: approve, total: total),
                ResultsEntry(id: "reject",  label: "No",         votes: reject,  total: total),
                ResultsEntry(id: "abstain", label: "Abstención", votes: abstain, total: total),
            ]
        default:
            return []
        }
    }

    private func winningEntryId(entries: [ResultsEntry], decision: Decision) -> String? {
        if let optionId = decision.winningOptionId { return optionId.uuidString }
        if decision.status == "approved" { return "approve" }
        if decision.status == "rejected" { return "reject" }
        return entries.max(by: { $0.votes < $1.votes })?.id
    }

    @ViewBuilder
    private func resultsRow(_ entry: ResultsEntry, isWinner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.label)
                    .font(.callout.weight(isWinner ? .semibold : .regular))
                Spacer()
                Text("\(entry.votes) \(entry.votes == 1 ? "voto" : "votos")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: entry.percent)
                .progressViewStyle(.linear)
                .tint(isWinner ? Color.accentColor : Color.accentColor.opacity(0.5))
            Text("\(Int((entry.percent * 100).rounded()))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 5. Participantes

    @ViewBuilder
    private func participantsSection(_ decision: Decision) -> some View {
        if !store.members.isEmpty {
            let preview = Array(participantsSorted().prefix(5))
            Section {
                ForEach(Array(preview.enumerated()), id: \.offset) { _, member in
                    participantRow(member, decision: decision)
                }
                if store.members.count > 5 {
                    Button {
                        isShowingAllParticipants = true
                    } label: {
                        Label("Ver todos (\(store.members.count))", systemImage: "list.bullet")
                    }
                }
            } header: {
                Text("Participantes (\(store.members.count))")
            }
        }
    }

    /// Ordena: faltantes primero, luego ya votaron — para que se entienda
    /// quién falta.
    private func participantsSorted() -> [ContextMember] {
        let votedIds = Set(store.votes.map(\.voterActorId))
        return store.members.sorted { a, b in
            let aVoted = votedIds.contains(a.actorId)
            let bVoted = votedIds.contains(b.actorId)
            if aVoted != bVoted { return !aVoted }
            return a.displayName < b.displayName
        }
    }

    @ViewBuilder
    private func participantRow(_ member: ContextMember, decision: Decision) -> some View {
        let vote = store.votes.first { $0.voterActorId == member.actorId }
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.actorId == myActorId ? "Tú" : member.displayName)
                Text(humanVoteStatus(vote: vote, decision: decision))
                    .font(.caption)
                    .foregroundStyle(vote == nil ? .orange : .green)
            }
        } icon: {
            ActorInitialsView(name: member.displayName, size: 36)
        }
    }

    private func humanVoteStatus(vote: DecisionVote?, decision: Decision) -> String {
        guard let vote else { return "No ha votado" }
        switch decision.voting {
        case .singleChoice:
            if let optionId = vote.optionId, let option = store.options.first(where: { $0.id == optionId }) {
                return "Votó \(option.title)"
            }
            if vote.vote == "abstain" { return "Se abstuvo" }
            return "Votó"
        case .multipleChoice:
            return "Votó"
        case .yesNoAbstain:
            switch vote.vote {
            case "approve": return "Votó a favor"
            case "reject":  return "Votó en contra"
            case "abstain": return "Se abstuvo"
            default:        return "Votó"
            }
        default:
            return "Votó"
        }
    }

    // MARK: - 6. ¿Qué ocurre si gana?

    @ViewBuilder
    private func consequencesSection(_ decision: Decision) -> some View {
        let items = consequences(decision)
        if !items.isEmpty {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    consequenceRow(item)
                }
            } header: {
                Text("¿Qué ocurre si gana?")
            }
        }
    }

    private struct ConsequenceItem {
        let title: String
        let body: String
    }

    private func consequences(_ decision: Decision) -> [ConsequenceItem] {
        switch decision.voting {
        case .singleChoice, .multipleChoice:
            return store.options.map { option in
                ConsequenceItem(
                    title: "Si gana \(option.title)",
                    body: option.description?.isEmpty == false
                        ? option.description!
                        : "Se aplicará la opción seleccionada."
                )
            }
        case .yesNoAbstain:
            let approveBody = decision.description?.isEmpty == false
                ? decision.description!
                : "Se aplicará la propuesta tal como fue planteada."
            return [
                ConsequenceItem(title: "Si se aprueba",  body: approveBody),
                ConsequenceItem(title: "Si se rechaza", body: "La decisión no se aplicará."),
            ]
        default:
            return []
        }
    }

    @ViewBuilder
    private func consequenceRow(_ item: ConsequenceItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                Text(item.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        } icon: {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.tint)
        }
    }

    // MARK: - 7. Actividad reciente

    @ViewBuilder
    private var activitySectionList: some View {
        if !decisionActivity.isEmpty {
            Section {
                // Issue 4 founder — preview de 5 → 3. Reduce scroll en la pantalla
                // dejando lo accionable más alcance del primer scroll.
                let preview = Array(decisionActivity.prefix(3))
                ForEach(Array(preview.enumerated()), id: \.offset) { _, activity in
                    activityRow(activity)
                }
                if decisionActivity.count > 3 {
                    Button {
                        isShowingFullActivity = true
                    } label: {
                        Label("Ver todo (\(decisionActivity.count))", systemImage: "list.bullet")
                    }
                }
            } header: {
                Text("Actividad reciente")
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: ActivityEvent) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(humanActivityTitle(activity))
                    .lineLimit(2)
                if let occurred = activity.occurredAt {
                    Text(occurred.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: activity.symbolName)
                .foregroundStyle(.tint)
        }
    }

    private func humanActivityTitle(_ activity: ActivityEvent) -> String {
        let actor = activity.actorId == myActorId
            ? "Tú"
            : store.displayName(for: activity.actorId)
        let body = activity.friendlyTitle(currentActorId: myActorId)
        if activity.isSystemGenerated || activity.actorId == nil { return body }
        return "\(actor): \(body)"
    }

    // MARK: - 8. Seguir esta decisión

    @ViewBuilder
    private var subscribeSectionList: some View {
        SubscribeSection(
            targetType: .decision,
            targetId: decisionId,
            store: container.subscriptionsStore
        )
    }

    // MARK: - 9. Administración

    @ViewBuilder
    private func adminSection(_ decision: Decision) -> some View {
        let actions = adminActions(decision)
        if hasManageAuthority && !actions.isEmpty {
            Section {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(role: action.role == .destructive ? .destructive : nil) {
                        handleAdminAction(action)
                    } label: {
                        adminRow(action)
                    }
                    .disabled(runner.isRunning || !action.enabled)
                }
            } header: {
                Text("Administración")
            }
        }
    }

    @ViewBuilder
    private func adminRow(_ action: AdminActionItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.label)
                if !action.enabled, let reason = action.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: action.symbol)
                .foregroundStyle(action.enabled ? action.tint : Color.secondary)
        }
    }

    /// Las acciones admin nacen de `availableActions[]` del backend. Sólo
    /// presentamos (ícono + tint + routing local). Nunca inferimos por status.
    private func adminActions(_ decision: Decision) -> [AdminActionItem] {
        var out: [AdminActionItem] = []
        for action in (store.detail?.availableActions ?? []) {
            switch action.actionKey {
            case "close_decision":
                out.append(AdminActionItem(
                    kind: .closeDecision,
                    label: action.label, reason: action.reason, enabled: action.enabled,
                    symbol: "stop.circle", tint: .orange
                ))
            case "execute_decision":
                out.append(AdminActionItem(
                    kind: .executeDecision,
                    label: action.label, reason: action.reason, enabled: action.enabled,
                    symbol: "play.circle.fill", tint: .purple
                ))
            case "cancel_decision":
                out.append(AdminActionItem(
                    kind: .cancelDecision,
                    label: action.label, reason: action.reason, enabled: action.enabled,
                    symbol: "xmark.circle", tint: .red, role: .destructive
                ))
            case "edit_decision":
                out.append(AdminActionItem(
                    kind: .editDecision,
                    label: action.label, reason: action.reason, enabled: action.enabled,
                    symbol: "pencil", tint: .purple
                ))
            default:
                break
            }
        }
        // Fallback compat — si el detail no llegó (best-effort failed) y el
        // summary aún concede los permisos, exponemos cerrar/ejecutar.
        if out.isEmpty {
            if decision.isOpen, store.canDo("close_decision") {
                out.append(AdminActionItem(
                    kind: .closeDecision, label: "Cerrar votación", reason: nil, enabled: true,
                    symbol: "stop.circle", tint: .orange
                ))
            }
            if decision.isApproved, store.canDo("execute_decision") {
                out.append(AdminActionItem(
                    kind: .executeDecision, label: "Ejecutar decisión", reason: nil, enabled: true,
                    symbol: "play.circle.fill", tint: .purple
                ))
            }
        }
        return out
    }

    private func handleAdminAction(_ action: AdminActionItem) {
        switch action.kind {
        case .closeDecision:   isConfirmingClose = true
        case .executeDecision: isConfirmingExecute = true
        case .cancelDecision:  isConfirmingCancel = true
        case .editDecision:    isShowingEdit = true
        }
    }

    // MARK: - 10. Auditoría

    @ViewBuilder
    private func auditSection(_ decision: Decision) -> some View {
        if hasManageAuthority {
            Section {
                if let created = decision.createdAt {
                    LabeledContent("Creada", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                if let by = decision.createdByActorId {
                    LabeledContent("Propuesta por", value: store.displayName(for: by))
                }
                if let closesAt = decision.closesAt {
                    LabeledContent("Cierre programado", value: closesAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let decidedAt = decision.decidedAt {
                    LabeledContent("Decidida", value: decidedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let executedAt = decision.executedAt {
                    LabeledContent("Ejecutada", value: executedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Estado", value: decision.status)
                LabeledContent("Modelo de voto", value: decision.voting.label)
                LabeledContent("Tipo", value: decision.type.label)
                LabeledContent {
                    Text(decision.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Text("ID")
                }
            } header: {
                Text("Auditoría")
            }
        }
    }

    // MARK: - Carga + helpers

    private func loadDecisionActivity() async {
        do {
            let all = try await container.rpc.listActivity(
                contextId: context.id,
                limit: 200,
                before: nil,
                includeDescendants: false
            )
            decisionActivity = all
                .filter { isRelatedToDecision($0) }
                .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
        } catch {
            decisionActivity = []
        }
    }

    private func isRelatedToDecision(_ activity: ActivityEvent) -> Bool {
        if activity.decisionId == decisionId { return true }
        if activity.subjectType == "decision" && activity.subjectId == decisionId { return true }
        if let payload = activity.payload {
            if payload["decision_id"]?.stringValue == decisionId.uuidString { return true }
        }
        return false
    }

    private func loadWhy(decisionId: UUID) async {
        isLoadingWhy = true
        defer { isLoadingWhy = false }
        do {
            whyResult = try await container.rpc.whyDecisionResult(decisionId: decisionId)
        } catch {
            whyResult = nil
        }
    }

    private func statusColor(_ status: String) -> Color {
        Theme.Status.decision(status)
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "open":      return "circle.dotted"
        case "approved":  return "checkmark.seal.fill"
        case "rejected":  return "xmark.seal.fill"
        case "executed":  return "play.circle.fill"
        case "cancelled": return "minus.circle.fill"
        default:          return "questionmark.circle"
        }
    }
}

// MARK: - Tipos de soporte

private enum AdminActionKind {
    case closeDecision, executeDecision, cancelDecision, editDecision
}

private struct AdminActionItem {
    enum Role { case standard, destructive }
    let kind: AdminActionKind
    let label: String
    let reason: String?
    let enabled: Bool
    let symbol: String
    let tint: Color
    var role: Role = .standard
}

// MARK: - WhyDecisionResult sheet

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
                        tallyCounter("A favor",   count: result.tally.approve, color: .green)
                        tallyCounter("En contra", count: result.tally.reject,  color: .red)
                        tallyCounter("Abstención", count: result.tally.abstain, color: .gray)
                        tallyCounter("Miembros",   count: result.activeMembers, color: .secondary)
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

// MARK: - Sheet: ver todos los participantes

private struct DecisionParticipantsFullView: View {
    let members: [ContextMember]
    let votes: [DecisionVote]
    let options: [DecisionOption]
    let voting: VotingModel
    let myActorId: UUID?
    let store: DecisionDetailStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(members) { member in
                let vote = votes.first { $0.voterActorId == member.actorId }
                HStack(spacing: 12) {
                    ActorInitialsView(name: member.displayName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.actorId == myActorId ? "Tú" : member.displayName)
                        Text(humanStatus(vote: vote))
                            .font(.caption)
                            .foregroundStyle(vote == nil ? .orange : .green)
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle("Participantes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }

    private func humanStatus(vote: DecisionVote?) -> String {
        guard let vote else { return "No ha votado" }
        switch voting {
        case .singleChoice:
            if let optionId = vote.optionId, let option = options.first(where: { $0.id == optionId }) {
                return "Votó \(option.title)"
            }
            if vote.vote == "abstain" { return "Se abstuvo" }
            return "Votó"
        case .multipleChoice:
            return "Votó"
        case .yesNoAbstain:
            switch vote.vote {
            case "approve": return "Votó a favor"
            case "reject":  return "Votó en contra"
            case "abstain": return "Se abstuvo"
            default:        return "Votó"
            }
        default:
            return "Votó"
        }
    }
}

// MARK: - Sheet: actividad completa de la decisión

private struct DecisionActivityFullView: View {
    let events: [ActivityEvent]
    let store: DecisionDetailStore
    let myActorId: UUID?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.symbolName)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line(for: event))
                            .font(.callout)
                        if let occurred = event.occurredAt {
                            Text(occurred.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle("Actividad de la decisión")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }

    private func line(for activity: ActivityEvent) -> String {
        let actor = activity.actorId == myActorId
            ? "Tú"
            : store.displayName(for: activity.actorId)
        let body = activity.friendlyTitle(currentActorId: myActorId)
        if activity.isSystemGenerated || activity.actorId == nil { return body }
        return "\(actor): \(body)"
    }
}

// MARK: - Previews

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
