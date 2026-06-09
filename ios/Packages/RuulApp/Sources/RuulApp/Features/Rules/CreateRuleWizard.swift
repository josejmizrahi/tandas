import SwiftUI
import RuulCore

/// F.8 — wizard de creación de reglas SIN JSON. El usuario elige una
/// plantilla (llegar tarde / cancelar mismo día / norma de texto), ajusta
/// los números y el wizard arma el condition_tree + consequences.
public struct CreateRuleWizard: View {
    let context: AppContext
    let store: RulesStore
    /// R.6.AI.4 — RPC injected para que el suggestion service pueda darle al
    /// modelo tools read-only (list members/resources/activity/rules) y
    /// personalizar la sugerencia con datos reales del contexto.
    let rpc: any RuulRPCClient

    @Environment(\.dismiss) private var dismiss
    @State private var template: Template = .lateFee
    @State private var thresholdMinutes = 15.0
    @State private var fineAmount = 100.0
    @State private var currency = "MXN"
    @State private var customTitle = ""
    @State private var normText = ""
    /// R.2S.5 — para `lateReservationCancel`: cancelar con menos de N horas → multa.
    @State private var lateCancelHours = 48.0
    /// R.2S.5 — para `expenseAlert`: monto a partir del cual la regla aplica.
    @State private var expenseThreshold = 5000.0
    @State private var runner = ActionRunner()
    /// R.6.AI.1 — Sugerencias on-device vía FoundationModels. Service hace
    /// graceful degradation si Apple Intelligence no está disponible.
    @State private var suggestionService = RuleSuggestionService()
    @State private var aiPromptText = ""
    /// R.6.AI.6 — Cuando el modelo aplica una sugerencia, los chips
    /// "Datos considerados" se siguen mostrando como confirmación. El user
    /// puede tocar "Pensar otra" para resetear y probar otro prompt.
    @State private var lastConsidered: [RuulAIContext.Considered] = []
    /// Picker manual queda colapsado por default — la primary action es AI.
    /// Se expande automáticamente cuando llega una sugerencia para que el
    /// user vea el template aplicado, o cuando el user lo abre a mano.
    @State private var isShowingManualPicker = false

    private enum Template: String, CaseIterable, Identifiable {
        case lateFee
        case sameDayCancellation
        case lateReservationCancel
        case expenseAlert
        case textNorm

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lateFee: return "Multa por llegar tarde"
            case .sameDayCancellation: return "Multa por cancelar el mismo día"
            case .lateReservationCancel: return "Multa por cancelar reservación tarde"
            case .expenseAlert: return "Alerta por gasto alto"
            case .textNorm: return "Norma de texto (sin automatización)"
            }
        }

        var symbolName: String {
            switch self {
            case .lateFee: return "clock.badge.exclamationmark"
            case .sameDayCancellation: return "xmark.circle"
            case .lateReservationCancel: return "calendar.badge.exclamationmark"
            case .expenseAlert: return "exclamationmark.triangle"
            case .textNorm: return "text.quote"
            }
        }
    }

    public init(context: AppContext, store: RulesStore, rpc: any RuulRPCClient) {
        self.context = context
        self.store = store
        self.rpc = rpc
    }

    public var body: some View {
        NavigationStack {
            Form {
                aiHeroSection

                Section {
                    DisclosureGroup(isExpanded: $isShowingManualPicker) {
                        ForEach(Template.allCases) { option in
                            Button {
                                template = option
                            } label: {
                                HStack {
                                    Label(option.label, systemImage: option.symbolName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if template == option {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Tipo de regla", systemImage: template.symbolName)
                            .symbolRenderingMode(.hierarchical)
                    }
                }

                switch template {
                case .lateFee:
                    Section("Condición") {
                        Stepper(
                            "Llegar más de \(Int(thresholdMinutes)) min tarde",
                            value: $thresholdMinutes,
                            in: 5...120,
                            step: 5
                        )
                    }
                    fineSection

                case .sameDayCancellation:
                    Section {
                        Text("Cancelar la asistencia el mismo día del evento")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Condición")
                    }
                    fineSection

                case .lateReservationCancel:
                    Section("Condición") {
                        Stepper(
                            "Cancelar con menos de \(Int(lateCancelHours)) h de anticipación",
                            value: $lateCancelHours,
                            in: 6...168,
                            step: 6
                        )
                    }
                    fineSection

                case .expenseAlert:
                    Section("Condición") {
                        HStack {
                            Text("Gasto mayor a")
                            TextField("Monto", value: $expenseThreshold, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(currency)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text("Por ahora la alerta queda como severidad alta sin consecuencia automática.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Consecuencia")
                    }

                case .textNorm:
                    Section("Norma") {
                        TextField("Título", text: $customTitle)
                        TextField("Describe el acuerdo…", text: $normText, axis: .vertical)
                            .lineLimit(3...6)
                    }
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear regla").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Nueva regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
    }

    // MARK: - R.6.AI.6 — AI Hero (FoundationModels + pre-aggregation)
    //
    // Hero AI-first: el usuario describe la regla con sus palabras, Ruul la
    // arma. Auto-apply al recibir sugerencia (sin tap "Aplicar" intermedio);
    // el form de abajo queda pre-lleno y editable. Chips de ejemplos para
    // arrancar rápido. Manual picker queda colapsado por default.

    @ViewBuilder
    private var aiHeroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                heroHeadline
                heroPromptField
                examplePromptsRow
                aiActionRow
                if !lastConsidered.isEmpty,
                   case .idle = suggestionService.phase {
                    consideredSection
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        } footer: {
            if !suggestionService.isAvailable, case .unavailable(let reason) = suggestionService.phase {
                Label(reason, systemImage: "sparkles.slash")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !lastConsidered.isEmpty {
                Text("La regla ya está armada abajo. Ajústala si quieres y dale Crear.")
            } else {
                Text("Descríbela con tus palabras o elige un tipo manualmente más abajo.")
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
                Text("Describe la regla y la armamos por ti")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var heroPromptField: some View {
        TextField(
            "Ej: si Aaron llega tarde, multa de 100",
            text: $aiPromptText,
            axis: .vertical
        )
        .lineLimit(3...6)
        .textInputAutocapitalization(.sentences)
        .submitLabel(.go)
        .disabled(!suggestionService.isAvailable || isSuggesting)
        .padding(12)
        .background(Theme.Background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var examplePromptsRow: some View {
        let examples = [
            "El que llega tarde paga 100",
            "Cancelar el mismo día = multa",
            "Si gastamos más de 5000, alerta",
            "Reservar y no usar = penalización"
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
                Label("Pensar regla", systemImage: "sparkles")
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

        case .loaded:
            // Phase will be auto-reset inside applySuggestion + lastConsidered
            // captura el manifest, así que prácticamente no entramos acá.
            EmptyView()

        case .unavailable:
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
                    Label("Pensar otra", systemImage: "arrow.clockwise")
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
            Image(systemName: consideredSymbol(item.id))
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

    private func consideredSymbol(_ id: String) -> String {
        switch id {
        case "members":      return "person.2.fill"
        case "resources":    return "shippingbox.fill"
        case "activity":     return "clock.arrow.circlepath"
        case "rules":        return "ruler.fill"
        case "obligations":  return "creditcard.fill"
        case "events":       return "calendar"
        default:             return "circle.dotted"
        }
    }

    private var isSuggesting: Bool {
        if case .loading = suggestionService.phase { return true }
        return false
    }

    /// Pide sugerencia y, al recibir, auto-aplica al form + abre el picker
    /// manual para que el user vea qué se eligió. Cero tap intermedio.
    private func suggest() async {
        await suggestionService.suggest(
            prompt: aiPromptText,
            rpc: rpc,
            contextId: context.id
        )
        if case .loaded(let suggestion, let considered) = suggestionService.phase {
            applySuggestion(suggestion)
            lastConsidered = considered
            isShowingManualPicker = true
            suggestionService.reset()
        }
    }

    private func applySuggestion(_ s: RuleSuggestion) {
        if let mapped = Template(rawValue: s.templateKey) {
            template = mapped
        }
        switch template {
        case .lateFee:
            if s.thresholdMinutes > 0 {
                thresholdMinutes = Double(min(max(s.thresholdMinutes, 5), 120))
            }
            if s.fineAmount > 0 { fineAmount = s.fineAmount }
        case .sameDayCancellation:
            if s.fineAmount > 0 { fineAmount = s.fineAmount }
        case .lateReservationCancel:
            if s.lateCancelHours > 0 {
                lateCancelHours = Double(min(max(s.lateCancelHours, 6), 168))
            }
            if s.fineAmount > 0 { fineAmount = s.fineAmount }
        case .expenseAlert:
            if s.expenseThreshold > 0 { expenseThreshold = s.expenseThreshold }
        case .textNorm:
            customTitle = s.title
            normText = s.normText
        }
    }

    @ViewBuilder
    private var fineSection: some View {
        Section("Consecuencia") {
            HStack {
                Text("Multa de")
                TextField("Monto", value: $fineAmount, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(currency)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isValid: Bool {
        switch template {
        case .lateFee, .sameDayCancellation, .lateReservationCancel:
            return fineAmount > 0
        case .expenseAlert:
            return expenseThreshold > 0
        case .textNorm:
            return !customTitle.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var footerText: String {
        switch template {
        case .lateFee:
            return "Cuando alguien haga check-in con más de \(Int(thresholdMinutes)) minutos de retraso, el backend le genera automáticamente una multa de $\(fineAmount.formatted(.number)) \(currency) a favor del contexto."
        case .sameDayCancellation:
            return "Cuando alguien cancele su asistencia el mismo día del evento, se le genera automáticamente una multa de $\(fineAmount.formatted(.number)) \(currency)."
        case .lateReservationCancel:
            return "Cuando alguien cancele una reservación con menos de \(Int(lateCancelHours)) h de anticipación, se le genera una multa de $\(fineAmount.formatted(.number)) \(currency)."
        case .expenseAlert:
            return "Cualquier gasto mayor a $\(expenseThreshold.formatted(.number)) \(currency) queda marcado con severidad alta para revisión."
        case .textNorm:
            return "Las normas de texto no generan consecuencias automáticas — son acuerdos visibles para todos."
        }
    }

    private func create() async {
        let success = await runner.run {
            let input: CreateRuleInput
            switch template {
            case .lateFee:
                input = CreateRuleInput(
                    contextId: context.id,
                    title: "Multa por llegar tarde (>\(Int(thresholdMinutes)) min)",
                    triggerEventType: RuleTrigger.checkedIn.rawValue,
                    conditionTree: RuleConditionBuilder.lateMoreThan(minutes: thresholdMinutes),
                    consequences: RuleConsequenceBuilder.fine(amount: fineAmount, currency: currency),
                    ruleType: "automation"
                )
            case .sameDayCancellation:
                input = CreateRuleInput(
                    contextId: context.id,
                    title: "Multa por cancelar el mismo día",
                    triggerEventType: RuleTrigger.participationCancelled.rawValue,
                    conditionTree: RuleConditionBuilder.sameDayCancellation(),
                    consequences: RuleConsequenceBuilder.fine(amount: fineAmount, currency: currency),
                    ruleType: "automation"
                )
            case .lateReservationCancel:
                input = CreateRuleInput(
                    contextId: context.id,
                    title: "Multa por cancelar reservación con menos de \(Int(lateCancelHours)) h",
                    triggerEventType: RuleTrigger.reservationCancelled.rawValue,
                    conditionTree: RuleConditionBuilderR2S5.cancelledLessHoursBefore(lateCancelHours),
                    consequences: RuleConsequenceBuilder.fine(amount: fineAmount, currency: currency),
                    ruleType: "automation",
                    targetScope: RuleTargetScope.reservation.rawValue
                )
            case .expenseAlert:
                input = CreateRuleInput(
                    contextId: context.id,
                    title: "Alerta de gasto mayor a \(expenseThreshold.formatted(.number)) \(currency)",
                    triggerEventType: RuleTrigger.moneyExpenseRecorded.rawValue,
                    conditionTree: RuleConditionBuilderR2S5.amountGreaterThan(expenseThreshold),
                    consequences: .array([]),
                    ruleType: "automation",
                    severity: 3,
                    targetScope: RuleTargetScope.moneyTransaction.rawValue,
                    targetFilter: RuleTargetFilterBuilder.currency(currency)
                )
            case .textNorm:
                input = CreateRuleInput(
                    contextId: context.id,
                    title: customTitle.trimmingCharacters(in: .whitespaces),
                    body: normText.isEmpty ? nil : normText,
                    ruleType: "norm"
                )
            }
            _ = try await store.createRule(input, context: context)
        }
        if success { dismiss() }
    }
}

#Preview("Crear regla") {
    let rpc = MockRuulRPCClient.demo()
    CreateRuleWizard(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: RulesStore(rpc: rpc),
        rpc: rpc
    )
}
