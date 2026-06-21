import SwiftUI
import RuulCore

/// F.DECISION.5 — editar título / descripción / fecha de cierre de una
/// decisión `open`. Acción canónica `edit_decision` gateada por autor o
/// `decisions.execute` en backend.
public struct EditDecisionView: View {
    let decision: Decision
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var closesAt: Date
    @State private var hasClosesAt: Bool
    @State private var runner = ActionRunner()

    public init(
        decision: Decision,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.decision = decision
        self.container = container
        self.onSaved = onSaved
        _title = State(initialValue: decision.title)
        _description = State(initialValue: decision.description ?? "")
        _closesAt = State(initialValue: decision.closesAt ?? Date().addingTimeInterval(7 * 24 * 3600))
        _hasClosesAt = State(initialValue: decision.closesAt != nil)
    }

    /// 7.C.1 (audit 2026-06-14) — `canSubmit` ahora requiere `hasChanges`
    /// para evitar PUT vacíos. Antes el botón Guardar quedaba habilitado
    /// aunque el usuario no hubiera cambiado nada.
    private var canSubmit: Bool {
        isValid && hasChanges && !runner.isRunning
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (!hasClosesAt || closesAt > Date())
    }

    private var hasChanges: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let newClosesAt = hasClosesAt ? closesAt : nil
        return trimmedTitle != decision.title
            || trimmedDescription != (decision.description ?? "")
            || newClosesAt != decision.closesAt
    }

    public var body: some View {
        NavigationStack {
            Form {
                // 7.C.1 — contexto de qué se está editando: voting model + status.
                // Antes el usuario abría "Editar" y no sabía si modificaba la
                // pregunta o los parámetros de votación.
                Section {
                    LabeledContent("Estado", value: decision.statusLabel)
                    LabeledContent("Modo de votación", value: decision.voting.label)
                } footer: {
                    Text("Esta pantalla solo edita la pregunta, el detalle y la fecha de cierre. El modo de votación y las opciones no se pueden cambiar después de abrirla.")
                }

                Section("Pregunta") {
                    TextField("Título", text: $title)
                    TextField("Detalles opcionales", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Toggle("Definir fecha de cierre", isOn: $hasClosesAt)
                    if hasClosesAt {
                        DatePicker("Cierra el", selection: $closesAt, in: Date()...)
                    }
                } header: {
                    Text("Cierre")
                } footer: {
                    Text("Al pasar esta fecha la votación se cerrará automáticamente y se contarán los votos emitidos hasta ese momento. Déjala en blanco para mantenerla abierta hasta que la cierres manualmente.")
                }
            }
            .navigationTitle("Editar votación")
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
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let newClosesAt = hasClosesAt ? closesAt : nil
        let input = UpdateDecisionInput(
            decisionId: decision.id,
            title: trimmedTitle == decision.title ? nil : trimmedTitle,
            description: trimmedDescription == (decision.description ?? "") ? nil : trimmedDescription,
            closesAt: newClosesAt == decision.closesAt ? nil : newClosesAt
        )
        let success = await runner.run {
            _ = try await container.rpc.updateDecision(input)
        }
        if success {
            onSaved()
            dismiss()
        }
    }
}

#Preview("Editar decisión") {
    EditDecisionView(
        decision: Decision(
            id: UUID(),
            contextActorId: UUID(),
            decisionType: "generic",
            title: "Subir cuota",
            description: "Propongo subir la cuota mensual.",
            status: "open",
            createdByActorId: UUID(),
            closesAt: Date().addingTimeInterval(7 * 24 * 3600)
        ),
        container: .demo(),
        onSaved: {}
    )
}
