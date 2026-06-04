import SwiftUI
import RuulCore

/// F.RULE.2 — editar nombre / acuerdo / severidad / estado (activa/pausada) de
/// una regla no archivada. Acción gateada por `rules.manage` en backend.
/// Los campos estructurales (trigger / condición / consecuencias) sólo se
/// crean por el wizard — aquí editamos lo legible.
public struct EditRuleView: View {
    let rule: Rule
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var body_: String
    @State private var severity: Int
    @State private var isActive: Bool
    @State private var runner = ActionRunner()

    public init(
        rule: Rule,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.rule = rule
        self.container = container
        self.onSaved = onSaved
        _title = State(initialValue: rule.title)
        _body_ = State(initialValue: rule.body ?? "")
        _severity = State(initialValue: rule.severity)
        _isActive = State(initialValue: rule.status == "active")
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !runner.isRunning
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Regla") {
                    TextField("Título", text: $title)
                    TextField("Acuerdo (opcional)", text: $body_, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Stepper(value: $severity, in: 1...5) {
                        HStack {
                            Text("Severidad")
                            Spacer()
                            Text("\(severity)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("1 = aviso suave · 5 = consecuencia fuerte. Sirve para ordenar y notificar.")
                }

                Section {
                    Toggle(isOn: $isActive) {
                        Label("Activa", systemImage: isActive ? "checkmark.seal.fill" : "pause.circle")
                    }
                } footer: {
                    Text(isActive
                         ? "La regla se evalúa cada vez que el evento disparador ocurre."
                         : "La regla está pausada. No se aplicará hasta que la actives.")
                }

                Section {
                    Label("Disparador, condición y consecuencia se editan re-creando la regla con el asistente.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Editar regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = body_.trimmingCharacters(in: .whitespaces)
        let newStatus = isActive ? "active" : "paused"
        let input = UpdateRuleInput(
            ruleId: rule.id,
            title: trimmedTitle == rule.title ? nil : trimmedTitle,
            body: trimmedBody == (rule.body ?? "") ? nil : trimmedBody,
            severity: severity == rule.severity ? nil : severity,
            status: newStatus == rule.status ? nil : newStatus
        )
        let success = await runner.run {
            _ = try await container.rpc.updateRule(input)
        }
        if success {
            onSaved()
            dismiss()
        }
    }
}
