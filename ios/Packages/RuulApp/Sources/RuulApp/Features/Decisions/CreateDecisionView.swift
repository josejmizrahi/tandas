import SwiftUI
import RuulCore

/// F.10 + R.2Q — proponer una decisión. Puede llegar precargada desde un conflicto
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
    @State private var votingModel: VotingModel
    @State private var optionDrafts: [DecisionOptionDraft] = []
    @State private var newOptionText: String = ""
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
        _store = State(initialValue: DecisionsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
        _title = State(initialValue: prefilledTitle)
        _decisionType = State(initialValue: prefilledType)
        // En conflictos de reservación el backend auto-seedea las 4 opciones,
        // así que mantenemos single_choice por defecto en ese flow.
        let defaultModel: VotingModel = conflictReference != nil ? .singleChoice : .yesNoAbstain
        _votingModel = State(initialValue: defaultModel)
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

            // R.2Q — voting model picker
            // En conflictos de reservación el modo es fijo (single_choice con
            // 4 opciones auto-seedeadas). En el resto, el usuario elige.
            if conflictReference == nil {
                Section {
                    Picker("Modo de votación", selection: $votingModel) {
                        ForEach(supportedVotingModels, id: \.self) { model in
                            Text(model.label).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text(votingModelHint)
                }
            }

            // R.2Q — opciones manuales para single_choice y multiple_choice no-disputa
            if (votingModel == .singleChoice || votingModel == .multipleChoice) && conflictReference == nil {
                optionsSection
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
                .disabled(!canSubmit || runner.isRunning)
            } footer: {
                Text(submitFooter)
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
        .ruulSheet()
    }

    // MARK: - Opciones (R.2Q)

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            ForEach(optionDrafts) { draft in
                HStack(spacing: 12) {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                    Text(draft.title)
                    Spacer()
                    Button(role: .destructive) {
                        optionDrafts.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("Nueva opción", text: $newOptionText)
                    .submitLabel(.done)
                    .onSubmit(addOption)
                Button {
                    addOption()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.large)
                }
                .disabled(newOptionText.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.plain)
            }
        } header: {
            Text("Opciones a votar")
        } footer: {
            Text("Agregá al menos dos opciones. Gana la más votada.")
        }
    }

    private func addOption() {
        let trimmed = newOptionText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        optionDrafts.append(DecisionOptionDraft(title: trimmed))
        newOptionText = ""
    }

    // MARK: - Helpers

    private var supportedVotingModels: [VotingModel] { [.yesNoAbstain, .singleChoice, .multipleChoice] }

    private var votingModelHint: String {
        switch votingModel {
        case .yesNoAbstain:
            return "Cada miembro vota a favor, en contra o abstención."
        case .singleChoice:
            return "Cada miembro elige una opción de las que definas abajo."
        case .multipleChoice:
            return "Cada miembro puede elegir varias opciones. El cierre es manual."
        default:
            return ""
        }
    }

    private var canSubmit: Bool {
        let titleOK = !title.trimmingCharacters(in: .whitespaces).isEmpty
        guard titleOK else { return false }
        if (votingModel == .singleChoice || votingModel == .multipleChoice) && conflictReference == nil {
            return optionDrafts.count >= 2
        }
        return true
    }

    private var submitFooter: String {
        switch votingModel {
        case .yesNoAbstain:
            return "Se aprueba con mayoría simple."
        case .singleChoice where conflictReference != nil:
            return "Las opciones de la disputa se crean automáticamente."
        case .singleChoice:
            return "Gana la opción más votada al pasar la mitad de los miembros o cuando todos voten."
        case .multipleChoice:
            return "Sin auto-cierre — el admin cierra cuando todos hayan votado."
        default:
            return ""
        }
    }

    private func create() async {
        let success = await runner.run {
            var payload: JSONValue?
            if let conflictReference {
                payload = .object(["conflict_id": .string(conflictReference.uuidString)])
            }
            let input = CreateDecisionInput(
                contextId: context.id,
                decisionType: decisionType,
                title: title.trimmingCharacters(in: .whitespaces),
                description: description.isEmpty ? nil : description,
                payload: payload,
                clientId: UUID().uuidString,
                votingModel: votingModel
            )
            if (votingModel == .singleChoice || votingModel == .multipleChoice) && conflictReference == nil {
                _ = try await store.createDecision(input, options: optionDrafts, context: context)
            } else {
                _ = try await store.createDecision(input, context: context)
            }
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
