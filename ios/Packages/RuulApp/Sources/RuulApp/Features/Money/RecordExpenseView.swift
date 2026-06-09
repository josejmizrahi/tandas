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

    public var id: UUID { eventId }

    public init(eventId: UUID, eventTitle: String, participantActorIds: Set<UUID>) {
        self.eventId = eventId
        self.eventTitle = eventTitle
        self.participantActorIds = participantActorIds
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
    @State private var runner = ActionRunner()
    @State private var resultNotice: String?
    /// R.6.AI.7 — AI hero state.
    @State private var suggestionService = ExpenseSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []

    private enum SplitMethod: String, CaseIterable, Identifiable {
        case equal = "Partes iguales"
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

    /// F.EVENT.6 — universo de miembros visibles. Cuando hay event scope,
    /// se reduce a los invitados al evento.
    private var visibleMembers: [ContextMember] {
        guard let scope = eventScope else { return store.members }
        return store.members.filter { scope.participantActorIds.contains($0.actorId) }
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
                // R.6.AI.7.fix3 — Quitamos el guard isEmpty: necesitamos
                // que members siempre esté fresco cuando AI aplica la
                // sugerencia. Sin members, el split queda en cero filas
                // y Registrar gasto disabled aunque AI armó todo bien.
                await store.load(context: context)
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

            Text(member.displayName)
                .foregroundStyle(isExcluded ? .secondary : .primary)
                .strikethrough(isExcluded)

            Spacer()

            if !isExcluded {
                switch splitMethod {
                case .equal:
                    if let amount, !participants.isEmpty {
                        Text((amount / Double(participants.count)).currencyLabel(nil))
                            .font(.callout)
                            .foregroundStyle(.secondary)
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

    private func record() async {
        guard let amount else { return }
        let success = await runner.run {
            let input: RecordExpenseInput
            if splitMethod == .custom {
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
        // Asegura que store.members esté listo ANTES de aplicar la sugerencia.
        // Si no, el matching de payerName/participantNames devuelve nil
        // (no hay contra qué matchear) y el split queda vacío → botón
        // Registrar disabled aunque el AI haya armado todo bien.
        if store.members.isEmpty {
            await store.load(context: context)
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
