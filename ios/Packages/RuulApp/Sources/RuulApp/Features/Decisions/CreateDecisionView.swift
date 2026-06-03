import SwiftUI
import RuulCore

/// F.10 — proponer una decisión. Puede llegar precargada desde un conflicto
/// de reservación (F.9 → "Escalar a votación").
public struct CreateDecisionView: View {
    let context: AppContext
    let container: DependencyContainer
    let conflictReference: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var store: DecisionsStore
    @State private var title: String
    @State private var description = ""
    @State private var decisionType: DecisionType
    @State private var runner = ActionRunner()

    public init(
        context: AppContext,
        container: DependencyContainer,
        prefilledTitle: String = "",
        prefilledType: DecisionType = .generic,
        conflictReference: UUID? = nil
    ) {
        self.context = context
        self.container = container
        self.conflictReference = conflictReference
        _store = State(initialValue: DecisionsStore(rpc: container.rpc))
        _title = State(initialValue: prefilledTitle)
        _decisionType = State(initialValue: prefilledType)
    }

    public var body: some View {
        Form {
            Section("Propuesta") {
                TextField("¿Qué hay que decidir?", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Contexto o detalles (opcional)", text: $description, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("Tipo") {
                Picker("Tipo", selection: $decisionType) {
                    ForEach(DecisionType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    if runner.isRunning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Proponer").frame(maxWidth: .infinity)
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
            } footer: {
                Text("La decisión queda abierta para que los miembros voten. Se aprueba con mayoría simple.")
            }
        }
        .navigationTitle("Nueva decisión")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
        }
        .actionErrorAlert(runner)
    }

    private func create() async {
        let success = await runner.run {
            var payload: JSONValue?
            if let conflictReference {
                payload = .object(["conflict_id": .string(conflictReference.uuidString)])
            }
            _ = try await store.createDecision(
                CreateDecisionInput(
                    contextId: context.id,
                    decisionType: decisionType,
                    title: title.trimmingCharacters(in: .whitespaces),
                    description: description.isEmpty ? nil : description,
                    payload: payload,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
    }
}

#Preview("Proponer decisión") {
    NavigationStack {
        CreateDecisionView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal"
            ),
            container: .demo()
        )
    }
}
