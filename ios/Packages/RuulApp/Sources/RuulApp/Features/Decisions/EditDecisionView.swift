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

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (!hasClosesAt || closesAt > Date())
            && !runner.isRunning
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Pregunta") {
                    TextField("Título", text: $title)
                    TextField("Contexto adicional (opcional)", text: $description, axis: .vertical)
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
                    Text("Al pasar esta fecha la votación se cerrará automáticamente. Déjala en blanco para mantenerla abierta hasta que la cierres manualmente.")
                }
            }
            .navigationTitle("Editar decisión")
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
