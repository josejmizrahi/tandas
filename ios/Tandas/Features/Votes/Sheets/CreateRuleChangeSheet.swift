import SwiftUI
import RuulUI
import RuulCore

/// Sheet para crear una vote de tipo `.ruleChange`. V1 solo permite cambiar
/// el monto flat de una regla existente — trigger/conditions/consequences
/// no son modificables. Picker selecciona regla, muestra el monto actual,
/// pide el nuevo monto + razón, y abre el voto via
/// `CreateRuleChangeCoordinator.submit()`.
struct CreateRuleChangeSheet: View {
    @Bindable var coordinator: CreateRuleChangeCoordinator
    var onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Regla a modificar") {
                    Picker("Selecciona regla", selection: Binding(
                        get: { coordinator.selectedRule?.id },
                        set: { newId in
                            coordinator.selectedRule = coordinator.availableRules.first { $0.id == newId }
                        }
                    )) {
                        Text("(Ninguna)").tag(UUID?.none)
                        ForEach(coordinator.availableRules) { rule in
                            Text(rule.title).tag(UUID?.some(rule.id))
                        }
                    }
                }

                if let rule = coordinator.selectedRule {
                    Section("Monto actual") {
                        Text(currentAmountLabel(for: rule))
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Section("Nuevo monto propuesto") {
                        TextField("$0", value: $coordinator.proposedAmount, format: .number)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Razón") {
                    TextField("¿Por qué cambiar el monto?", text: $coordinator.reason, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Stepper(value: $coordinator.durationHours, in: 1...168) {
                        Text("Cierra en \(coordinator.durationHours)h")
                    }
                } header: {
                    Text("Duración")
                } footer: {
                    Text("La votación cerrará automáticamente.")
                }

                if let error = coordinator.error {
                    Section {
                        Text(error).foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .navigationTitle("Cambio de regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abrir voto") {
                        Task {
                            await coordinator.submit()
                            if let id = coordinator.createdVoteId {
                                dismiss()
                                onCreated(id)
                            }
                        }
                    }
                    .disabled(!coordinator.canSubmit)
                }
            }
        }
    }

    private func currentAmountLabel(for rule: GroupRule) -> String {
        switch rule.fineShape {
        case .flat(let amount):
            return "$\(amount)"
        case .escalating(let base, let step, let stepMinutes):
            return "$\(base) + $\(step) cada \(stepMinutes)min"
        case .none:
            return "(sin monto definido)"
        case .unknown:
            return "(monto no editable)"
        }
    }
}
