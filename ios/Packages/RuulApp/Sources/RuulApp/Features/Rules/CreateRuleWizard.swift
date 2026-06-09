import SwiftUI
import RuulCore

/// F.8 — wizard de creación de reglas SIN JSON. El usuario elige una
/// plantilla (llegar tarde / cancelar mismo día / norma de texto), ajusta
/// los números y el wizard arma el condition_tree + consequences.
public struct CreateRuleWizard: View {
    let context: AppContext
    let store: RulesStore

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

    public init(context: AppContext, store: RulesStore) {
        self.context = context
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                aiSuggestionSection

                Section("Tipo de regla") {
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
                                }
                            }
                        }
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

    // MARK: - R.6.AI.1 — AI Suggestion (FoundationModels)

    @ViewBuilder
    private var aiSuggestionSection: some View {
        Section {
            TextField(
                "Describe la regla con tus palabras…",
                text: $aiPromptText,
                axis: .vertical
            )
            .lineLimit(2...4)
            .disabled(!suggestionService.isAvailable || isSuggesting)

            switch suggestionService.phase {
            case .idle, .loaded:
                Button {
                    Task { await suggestionService.suggest(prompt: aiPromptText) }
                } label: {
                    Label("Sugerir regla", systemImage: "sparkles")
                        .symbolRenderingMode(.hierarchical)
                        .frame(maxWidth: .infinity)
                }
                .disabled(
                    aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !suggestionService.isAvailable
                )
            case .loading:
                HStack {
                    ProgressView()
                    Text("Pensando…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            case .unavailable(let reason):
                Label(reason, systemImage: "sparkles.slash")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(Theme.Tint.critical)
            }

            if case .loaded(let suggestion) = suggestionService.phase {
                suggestionPreview(suggestion)
            }
        } header: {
            Label("Sugerencia con Apple Intelligence", systemImage: "sparkles")
        } footer: {
            if suggestionService.isAvailable {
                Text("La sugerencia pre-llena el wizard. Tú decides si la creas tal cual o ajustas los valores antes.")
            }
        }
    }

    private var isSuggesting: Bool {
        if case .loading = suggestionService.phase { return true }
        return false
    }

    @ViewBuilder
    private func suggestionPreview(_ suggestion: RuleSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(suggestion.rationale)
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
        }

        Button {
            applySuggestion(suggestion)
            suggestionService.reset()
        } label: {
            Label("Aplicar sugerencia", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .frame(maxWidth: .infinity)
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
    CreateRuleWizard(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: RulesStore(rpc: MockRuulRPCClient.demo())
    )
}
