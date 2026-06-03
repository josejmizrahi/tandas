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
    @State private var runner = ActionRunner()

    private enum Template: String, CaseIterable, Identifiable {
        case lateFee
        case sameDayCancellation
        case textNorm

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lateFee: return "Multa por llegar tarde"
            case .sameDayCancellation: return "Multa por cancelar el mismo día"
            case .textNorm: return "Norma de texto (sin automatización)"
            }
        }

        var symbolName: String {
            switch self {
            case .lateFee: return "clock.badge.exclamationmark"
            case .sameDayCancellation: return "xmark.circle"
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
        case .lateFee, .sameDayCancellation:
            return fineAmount > 0
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
