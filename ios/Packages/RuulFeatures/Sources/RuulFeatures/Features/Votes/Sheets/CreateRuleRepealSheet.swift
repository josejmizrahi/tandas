import SwiftUI
import RuulUI
import RuulCore

/// Sheet para abrir una votación `.ruleRepeal` ("Archivar regla"). V1
/// minimal — picker de regla + razón. Si pasa, el trigger SQL
/// `archive_rule_on_repeal_pass` (mig 00347) marca la regla como
/// archivada server-side.
public struct CreateRuleRepealSheet: View {
    @Bindable var coordinator: CreateRuleRepealCoordinator
    public var onCreated: (UUID) -> Void

    public init(coordinator: CreateRuleRepealCoordinator, onCreated: @escaping (UUID) -> Void) {
        self.coordinator = coordinator
        self.onCreated = onCreated
    }

    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            Form {
                Section("Regla a archivar") {
                    Picker("Selecciona regla", selection: Binding(
                        get: { coordinator.selectedRule?.id },
                        set: { newId in
                            coordinator.selectedRule = coordinator.availableRules.first { $0.id == newId }
                        }
                    )) {
                        Text("(Ninguna)").tag(UUID?.none)
                        ForEach(coordinator.availableRules) { rule in
                            Text(rule.name).tag(UUID?.some(rule.id))
                        }
                    }
                }

                Section("Razón") {
                    TextField("¿Por qué archivar esta regla?", text: $coordinator.reason, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Stepper(value: $coordinator.durationHours, in: 1...168) {
                        Text("Cierra en \(coordinator.durationHours)h")
                    }
                } header: {
                    Text("Duración")
                } footer: {
                    Text("Si la mayoría aprueba, la regla queda archivada y deja de aplicarse.")
                }

                if let error = coordinator.error {
                    Section {
                        Text(error).foregroundStyle(Color.red)
                    }
                }
            }
            .ruulSheetToolbar("Archivar regla")
            .toolbar {
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
}
