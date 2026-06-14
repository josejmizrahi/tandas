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

    /// 7.C.1 (audit 2026-06-14) — `canSubmit` ahora requiere `hasChanges`.
    private var canSubmit: Bool {
        isValid && hasChanges && !runner.isRunning
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasChanges: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = body_.trimmingCharacters(in: .whitespaces)
        let newStatus = isActive ? "active" : "paused"
        return trimmedTitle != rule.title
            || trimmedBody != (rule.body ?? "")
            || severity != rule.severity
            || newStatus != rule.status
    }

    public var body: some View {
        NavigationStack {
            Form {
                // 7.C.1 — contexto de qué disparador / scope tiene la regla,
                // para que el usuario entienda QUÉ está editando antes de
                // cambiar título o severidad.
                Section {
                    LabeledContent("Disparador", value: rule.triggerHumanLabel)
                    LabeledContent("Estado", value: rule.isActive ? "Activa" : "Pausada")
                } footer: {
                    Text("Esta pantalla edita lo legible (título, acuerdo y severidad). El disparador, la condición y la consecuencia se modifican con el asistente.")
                }

                Section("Regla") {
                    TextField("Título", text: $title)
                    TextField("Acuerdo (opcional)", text: $body_, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Stepper(value: $severity, in: 1...5) {
                        HStack(spacing: 10) {
                            Text("Severidad")
                            Spacer()
                            // 7.C.1 — escala visual: tint + label semántico.
                            Label(severityLabel, systemImage: severitySymbol)
                                .foregroundStyle(severityTint)
                                .font(.callout.weight(.semibold))
                        }
                    }
                } footer: {
                    Text("Sirve para ordenar prioridades y decidir si genera notificación o solo aparece en el historial.")
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

    // 7.C.1 — escala semántica de severidad.

    private var severityLabel: String {
        switch severity {
        case 1: return "Aviso suave"
        case 2: return "Recordatorio"
        case 3: return "Atención"
        case 4: return "Importante"
        case 5: return "Consecuencia fuerte"
        default: return "Nivel \(severity)"
        }
    }

    private var severitySymbol: String {
        switch severity {
        case 1: return "info.circle.fill"
        case 2: return "bell.fill"
        case 3: return "exclamationmark.circle.fill"
        case 4: return "exclamationmark.triangle.fill"
        case 5: return "exclamationmark.octagon.fill"
        default: return "circle.fill"
        }
    }

    private var severityTint: Color {
        switch severity {
        case 1: return Theme.Tint.info
        case 2: return Theme.Tint.primary
        case 3: return Theme.Tint.warning
        case 4: return Theme.Tint.warning
        case 5: return Theme.Tint.critical
        default: return Theme.Text.secondary
        }
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
