import SwiftUI
import RuulCore

/// F.EVENT.6 — un gasto puede estar atado a un evento. Cuando llega un
/// `EventScope`, la vista limita el universo de participantes (split + paid-by)
/// a los invitados de ese evento y le pasa `eventId` al backend para que las
/// obligations queden relacionadas (`obligations.source_event_id`).
public struct EventScope: Sendable, Equatable, Identifiable {
    public let eventId: UUID
    public let eventTitle: String
    public let participantActorIds: Set<UUID>
    /// R.5Z.fix.EVENT.SPLIT — peso por participant (1 + plus_count + guest_shares
    /// invitados por ese actor). Cuando alguno > 1, el split equal se reparte
    /// proporcionalmente: monto_por_actor = total * weight / sum(weights).
    /// Si vacío o todos == 1, se comporta como split equal estándar.
    public let weights: [UUID: Int]

    public var id: UUID { eventId }

    public init(eventId: UUID, eventTitle: String, participantActorIds: Set<UUID>, weights: [UUID: Int] = [:]) {
        self.eventId = eventId
        self.eventTitle = eventTitle
        self.participantActorIds = participantActorIds
        self.weights = weights
    }

    /// Peso de un actor (default 1). Cuando todos los weights son 1 o vacío,
    /// el split es equal estándar.
    public func weight(for actorId: UUID) -> Int {
        weights[actorId] ?? 1
    }

    /// `true` si hay al menos un peso > 1 → split se hace proporcional.
    public var hasWeights: Bool { weights.values.contains(where: { $0 > 1 }) }

    /// Suma de pesos de los actores activos (los de `participantActorIds`).
    public var totalWeight: Int {
        participantActorIds.reduce(0) { $0 + weight(for: $1) }
    }
}

/// F.11 — registrar un gasto con split equal o custom (SplitEditor).
/// El backend crea las obligations de cada deudor hacia quien pagó.
public struct RecordExpenseView: View {
    let context: AppContext
    let store: MoneyStore
    let container: DependencyContainer
    /// F.EVENT.6 — cuando viene desde un EventDetail, restringe miembros al
    /// roster del evento y manda `eventId` al backend.
    let eventScope: EventScope?

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var amountText = ""
    @State private var currency = "MXN"
    @State private var paidByActorId: UUID?
    @State private var splitMethod: SplitMethod = .equal
    @State private var excludedActorIds: Set<UUID> = []
    @State private var customAmounts: [UUID: String] = [:]
    /// R.5Z.fix.EVENT.SPLIT.SHARES (founder 2026-06-10) — partes por persona
    /// estilo Splitwise. 0 = excluido. Default 1. Pre-poblado con
    /// eventScope.weights cuando el gasto viene de un evento.
    @State private var shareCounts: [UUID: Int] = [:]
    @State private var runner = ActionRunner()
    @State private var resultNotice: String?
    /// R.6.AI.7 — AI hero state.
    @State private var suggestionService = ExpenseSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []
    /// R.6.AI.7.fix4 — Fallback de miembros si `store.members` queda vacío
    /// (e.g., `MoneyStore.load` falló en una de sus dos RPCs paralelas).
    /// Garantiza que el split + matching de AI tengan contra qué trabajar.
    @State private var fallbackMembers: [ContextMember] = []

    private enum SplitMethod: String, CaseIterable, Identifiable {
        case equal = "Partes iguales"
        case shares = "Por partes"
        case custom = "Montos personalizados"
        var id: String { rawValue }
    }

    public init(
        context: AppContext,
        store: MoneyStore,
        container: DependencyContainer,
        eventScope: EventScope? = nil
    ) {
        self.context = context
        self.store = store
        self.container = container
        self.eventScope = eventScope
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }
    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: "")) }

    /// Source de miembros con fallback: prefer store.members; si está vacío
    /// (MoneyStore.load pudo haber fallado en su rama paralela), usa
    /// fallbackMembers que la vista fetchea directo de context_summary.
    private var resolvedMembers: [ContextMember] {
        store.members.isEmpty ? fallbackMembers : store.members
    }

    /// F.EVENT.6 — universo de miembros visibles. Cuando hay event scope,
    /// se reduce a los invitados al evento.
    private var visibleMembers: [ContextMember] {
        guard let scope = eventScope else { return resolvedMembers }
        return resolvedMembers.filter { scope.participantActorIds.contains($0.actorId) }
    }

    /// Miembros que participan en el split (no excluidos).
    private var participants: [ContextMember] {
        visibleMembers.filter { !excludedActorIds.contains($0.actorId) }
    }

    public var body: some View {
        NavigationStack {
            Form {
                aiHeroSection

                Section("Gasto") {
                    TextField("¿Qué se pagó? (Cena, súper…)", text: $description)
                    HStack {
                        Text("$")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        TextField("MXN", text: $currency)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let scope = eventScope {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .foregroundStyle(.tint)
                            Text("Asociado a \(scope.eventTitle)")
                                .font(.callout)
                            Spacer()
                        }
                    } footer: {
                        Text("El reparto se limita a los \(scope.participantActorIds.count) invitado(s) del evento.")
                    }
                }

                Section("Quién pagó") {
                    Menu {
                        Button {
                            paidByActorId = nil
                        } label: {
                            Label("Yo", systemImage: paidByActorId == nil ? "checkmark" : "")
                        }
                        ForEach(visibleMembers) { member in
                            Button {
                                paidByActorId = member.actorId
                            } label: {
                                Label(
                                    member.displayName,
                                    systemImage: paidByActorId == member.actorId ? "checkmark" : ""
                                )
                            }
                        }
                    } label: {
                        HStack {
                            Text(payerDisplayName)
                                .foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }

                // SplitEditor
                Section("Cómo se reparte") {
                    Picker("Método", selection: $splitMethod) {
                        ForEach(SplitMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    ForEach(visibleMembers) { member in
                        splitRow(member)
                    }
                }

                splitSummarySection

                Section {
                    Button {
                        Task { await record() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Registrar gasto").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                }
            }
            .navigationTitle("Registrar gasto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                async let summaryTask = container.rpc.contextSummary(contextId: context.id)
                async let storeLoad: () = store.load(context: context)
                if let summary = try? await summaryTask {
                    fallbackMembers = summary.members
                }
                _ = await storeLoad
                // R.5Z.fix.EVENT.SPLIT.SHARES — pre-fill shares from event
                // weights y default a método "Por partes" cuando el evento
                // tiene pesos (plus_count + guests). El founder puede
                // ajustar libremente cada Stepper antes de registrar.
                if let scope = eventScope, scope.hasWeights, shareCounts.isEmpty {
                    var initial: [UUID: Int] = [:]
                    for actorId in scope.participantActorIds {
                        initial[actorId] = scope.weight(for: actorId)
                    }
                    shareCounts = initial
                    splitMethod = .shares
                }
            }
            .actionErrorAlert(runner)
            .alert("Gasto registrado", isPresented: Binding(
                get: { resultNotice != nil },
                set: { if !$0 { resultNotice = nil; dismiss() } }
            )) {
                Button("OK") {
                    resultNotice = nil
                    dismiss()
                }
            } message: {
                Text(resultNotice ?? "")
            }
        }
        .ruulSheet()
    }

    // MARK: - SplitEditor rows

    @ViewBuilder
    private func splitRow(_ member: ContextMember) -> some View {
        let isExcluded = excludedActorIds.contains(member.actorId)

        HStack(spacing: 12) {
            Button {
                toggleExclusion(member.actorId)
            } label: {
                Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(isExcluded ? Color.secondary : Color.accentColor)
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .foregroundStyle(isExcluded ? .secondary : .primary)
                        .strikethrough(isExcluded)
                    // R.5Z.fix.EVENT.SPLIT.WEIGHTS — badge ×N cuando este actor
                    // tiene peso > 1 por plus_count + guests invitados.
                    if let scope = eventScope, scope.weight(for: member.actorId) > 1 {
                        Text("×\(scope.weight(for: member.actorId))")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Spacer()

            if !isExcluded {
                switch splitMethod {
                case .equal:
                    if let amount, !participants.isEmpty {
                        Text((amount / Double(participants.count)).currencyLabel(nil))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .shares:
                    // R.5Z.fix.EVENT.SPLIT.SHARES — Stepper de partes + preview.
                    let shares = shareCounts[member.actorId] ?? 1
                    HStack(spacing: 8) {
                        Stepper(value: Binding(
                            get: { shareCounts[member.actorId] ?? 1 },
                            set: { shareCounts[member.actorId] = max(0, $0) }
                        ), in: 0...20) {
                            Text("\(shares) \(shares == 1 ? "parte" : "partes")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.Text.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        .labelsHidden()
                        if let amount, totalShares > 0, shares > 0 {
                            let share = amount * Double(shares) / Double(totalShares)
                            Text(share.currencyLabel(nil))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                case .custom:
                    TextField("0.00", text: Binding(
                        get: { customAmounts[member.actorId] ?? "" },
                        set: { customAmounts[member.actorId] = $0 }
                    ))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    @ViewBuilder
    private var splitSummarySection: some View {
        if splitMethod == .custom, let amount {
            let total = customTotal
            Section {
                HStack {
                    Text("Suma del reparto")
                    Spacer()
                    Text(total.currencyLabel(currency))
                        .foregroundStyle(abs(total - amount) < 0.01 ? .green : .red)
                }
                if abs(total - amount) >= 0.01 {
                    Text("Debe sumar exactamente \(amount.currencyLabel(currency))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Lógica

    private var customTotal: Double {
        participants.reduce(0) { sum, member in
            sum + (Double(customAmounts[member.actorId] ?? "") ?? 0)
        }
    }

    private var isValid: Bool {
        guard let amount, amount > 0,
              !description.trimmingCharacters(in: .whitespaces).isEmpty,
              !participants.isEmpty else { return false }
        if splitMethod == .custom {
            return abs(customTotal - amount) < 0.01
        }
        return true
    }

    private func toggleExclusion(_ actorId: UUID) {
        if excludedActorIds.contains(actorId) {
            excludedActorIds.remove(actorId)
        } else {
            excludedActorIds.insert(actorId)
            customAmounts[actorId] = nil
        }
    }

    /// R.5Z.fix.EVENT.SPLIT.SHARES — suma de partes asignadas a participants
    /// no excluidos. 0 si nadie tiene partes.
    private var totalShares: Int {
        participants.reduce(0) { $0 + max(0, shareCounts[$1.actorId] ?? 1) }
    }

    private func record() async {
        guard let amount else { return }
        let success = await runner.run {
            let input: RecordExpenseInput
            if splitMethod == .shares, totalShares > 0 {
                // R.5Z.fix.EVENT.SPLIT.SHARES — Splitwise-style: cada participant
                // tiene N partes (0 = excluido). Monto = total × shares / sum_shares.
                // Para evitar drift de redondeo, el último con shares > 0 recibe el
                // ajuste residual para que sum(amounts) == total exacto.
                let denom = Double(totalShares)
                var assignments: [(member: ContextMember, shares: Int, amount: Double)] = []
                for member in participants {
                    let shares = max(0, shareCounts[member.actorId] ?? 1)
                    guard shares > 0 else { continue }
                    let raw = (amount * Double(shares) / denom * 100).rounded() / 100
                    assignments.append((member, shares, raw))
                }
                let preliminarySum = assignments.reduce(0.0) { $0 + $1.amount }
                let delta = ((amount - preliminarySum) * 100).rounded() / 100
                if !assignments.isEmpty, delta != 0 {
                    assignments[assignments.count - 1].amount += delta
                }
                let splits = assignments.map { ExpenseSplit(actorId: $0.member.actorId, amount: $0.amount) }
                input = RecordExpenseInput(
                    contextId: context.id,
                    amount: amount,
                    currency: currency,
                    description: description.trimmingCharacters(in: .whitespaces),
                    splitMethod: "custom",
                    splits: splits,
                    eventId: eventScope?.eventId,
                    paidByActorId: paidByActorId,
                    clientId: UUID().uuidString
                )
            } else if splitMethod == .equal,
               let scope = eventScope, scope.hasWeights {
                let activeWeights = participants.reduce(into: 0) { acc, m in
                    acc += scope.weight(for: m.actorId)
                }
                let totalWeight = Double(max(activeWeights, 1))
                let splits = participants.map { member -> ExpenseSplit in
                    let w = Double(scope.weight(for: member.actorId))
                    let share = (amount * w / totalWeight * 100).rounded() / 100
                    return ExpenseSplit(actorId: member.actorId, amount: share)
                }
                input = RecordExpenseInput(
                    contextId: context.id,
                    amount: amount,
                    currency: currency,
                    description: description.trimmingCharacters(in: .whitespaces),
                    splitMethod: "custom",
                    splits: splits,
                    eventId: eventScope?.eventId,
                    paidByActorId: paidByActorId,
                    clientId: UUID().uuidString
                )
            } else if splitMethod == .custom {
                let splits = participants.compactMap { member -> ExpenseSplit? in
                    guard let value = Double(customAmounts[member.actorId] ?? ""), value > 0 else { return nil }
                    return ExpenseSplit(actorId: member.actorId, amount: value)
                }
                input = RecordExpenseInput(
                    contextId: context.id,
                    amount: amount,
                    currency: currency,
                    description: description.trimmingCharacters(in: .whitespaces),
                    splitMethod: "custom",
                    splits: splits,
                    eventId: eventScope?.eventId,
                    paidByActorId: paidByActorId,
                    clientId: UUID().uuidString
                )
            } else {
                input = RecordExpenseInput(
                    contextId: context.id,
                    amount: amount,
                    currency: currency,
                    description: description.trimmingCharacters(in: .whitespaces),
                    splitWith: participants.map(\.actorId),
                    excludedActorIds: excludedActorIds.isEmpty ? nil : Array(excludedActorIds),
                    splitMethod: "equal",
                    eventId: eventScope?.eventId,
                    paidByActorId: paidByActorId,
                    clientId: UUID().uuidString
                )
            }
            let result = try await store.recordExpense(input, context: context)
            if let share = result.sharePerPerson {
                resultNotice = "Cada quien debe \(share.currencyLabel(currency)) a \(payerName)."
            } else {
                resultNotice = "Se crearon \(result.obligations.count) deudas hacia \(payerName)."
            }
        }
        if !success {
            resultNotice = nil
        }
    }

    private var payerName: String {
        if let paidByActorId {
            return store.displayName(for: paidByActorId)
        }
        return "ti"
    }

    /// R.6.AI.7.fix3 — Display name del pagador para el Menu label. Mismo
    /// que payerName pero para uso en SwiftUI label (no en string interp).
    private var payerDisplayName: String {
        guard let paidByActorId else { return "Yo" }
        return visibleMembers.first(where: { $0.actorId == paidByActorId })?.displayName ?? "Yo"
    }

    // MARK: - R.6.AI.7 — AI Hero (Apple Intelligence)
    //
    // Pídele a Ruul que arme el gasto en lenguaje natural: "Cena 500 yo
    // pagué" → description + amount + payer + currency llenos. Mismo
    // patrón pre-aggregation que R.6.AI.5/6: 1 RPC para fetch members,
    // prefix compacto, guided generation. Auto-apply al recibir.

    @ViewBuilder
    private var aiHeroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                heroHeadline
                heroPromptField
                examplePromptsRow
                aiActionRow
                if !lastConsidered.isEmpty, case .idle = suggestionService.phase {
                    consideredSection
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        } footer: {
            if !suggestionService.isAvailable,
               case .unavailable(let reason) = suggestionService.phase {
                Label(reason, systemImage: "sparkles.slash")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !lastConsidered.isEmpty {
                Text("El gasto ya está armado abajo. Ajústalo si quieres y dale Registrar.")
            } else {
                Text("Descríbelo con tus palabras o llena los campos manualmente.")
            }
        }
    }

    @ViewBuilder
    private var heroHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pídele a Ruul")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Describe el gasto y lo armamos por ti")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var heroPromptField: some View {
        TextField(
            "Ej: cena 500 yo pagué, dividido entre todos",
            text: $aiPromptText,
            axis: .vertical
        )
        .lineLimit(2...5)
        .textInputAutocapitalization(.sentences)
        .disabled(!suggestionService.isAvailable || isSuggesting)
        .padding(12)
        .background(Theme.Background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var examplePromptsRow: some View {
        let examples = [
            "Cena 500 yo pagué",
            "Súper 250 pagó Aaron",
            "Uber 80 sin Juan",
            "Gasolina 600 USD"
        ]
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        aiPromptText = example
                    } label: {
                        Text(example)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.Tint.primary.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.Tint.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!suggestionService.isAvailable || isSuggesting)
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var aiActionRow: some View {
        switch suggestionService.phase {
        case .idle:
            Button {
                Task { await suggest() }
            } label: {
                Label("Pensar gasto", systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(
                aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !suggestionService.isAvailable
            )

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Pensando…")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)

        case .loaded, .unavailable:
            EmptyView()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(Theme.Tint.critical)
                Button {
                    Task { await suggest() }
                } label: {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    private var consideredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Datos considerados")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Text.tertiary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    lastConsidered = []
                    aiPromptText = ""
                    suggestionService.reset()
                } label: {
                    Label("Pensar otro", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.medium))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Tint.primary)
            }
            ForEach(lastConsidered) { item in
                consideredChip(item)
            }
        }
        .padding(12)
        .background(Theme.Tint.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func consideredChip(_ item: RuulAIContext.Considered) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.caption2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.info)
                .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text(item.summary)
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var isSuggesting: Bool {
        if case .loading = suggestionService.phase { return true }
        return false
    }

    private func suggest() async {
        // R.6.AI.7.fix4 — Garantiza que tengamos members (store o fallback)
        // antes de que AI aplique. Sin members, applySuggestion no puede
        // hacer match de payerName/participantNames y el split queda vacío.
        if store.members.isEmpty {
            await store.load(context: context)
        }
        if store.members.isEmpty && fallbackMembers.isEmpty {
            if let summary = try? await container.rpc.contextSummary(contextId: context.id) {
                fallbackMembers = summary.members
            }
        }
        await suggestionService.suggest(
            prompt: aiPromptText,
            rpc: container.rpc,
            contextId: context.id
        )
        if case .loaded(let suggestion, let considered) = suggestionService.phase {
            applySuggestion(suggestion)
            lastConsidered = considered
            suggestionService.reset()
        }
    }

    private func applySuggestion(_ s: ExpenseSuggestion) {
        if !s.description.isEmpty { description = s.description }
        if s.amount > 0 { amountText = formatAmount(s.amount) }
        if !s.currency.isEmpty { currency = s.currency.uppercased() }

        // R.6.AI.7.fix — payerName vacío significa "yo pagué" (paidByActorId=nil).
        // Esto soluciona el bug donde el modelo dejaba un paidByActorId stale del
        // intent previo. Aplicamos siempre: nombre → match, vacío → nil.
        if s.payerName.isEmpty {
            paidByActorId = nil
        } else if let match = matchMember(name: s.payerName) {
            paidByActorId = match.actorId
        }

        // participantNames lista los miembros que SÍ participan en el split.
        // Vacío = todos (default). Si llega lleno, excluimos a todos los demás.
        if s.participantNames.trimmingCharacters(in: .whitespaces).isEmpty {
            excludedActorIds = []
        } else {
            let names = s.participantNames
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let participantIds = Set(names.compactMap { matchMember(name: $0)?.actorId })
            if participantIds.isEmpty {
                excludedActorIds = []
            } else {
                let allIds = Set(visibleMembers.map(\.actorId))
                excludedActorIds = allIds.subtracting(participantIds)
            }
        }
    }

    private func matchMember(name: String) -> ContextMember? {
        let needle = name.lowercased().trimmingCharacters(in: .whitespaces)
        // Match exacto primero, después contiene.
        if let exact = visibleMembers.first(where: { $0.displayName.lowercased() == needle }) {
            return exact
        }
        return visibleMembers.first { $0.displayName.lowercased().contains(needle) }
    }

    private func formatAmount(_ amount: Double) -> String {
        if amount.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(amount))
        }
        return String(format: "%.2f", amount)
    }
}

#Preview("Registrar gasto") {
    RecordExpenseView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: MoneyStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
