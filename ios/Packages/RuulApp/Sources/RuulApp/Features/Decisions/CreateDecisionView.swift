import SwiftUI
import RuulCore

/// F.10 + R.2Q — proponer una decisión. Puede llegar precargada desde un conflicto
/// de reservación (F.9 → "Escalar a votación").
public struct CreateDecisionView: View {
    let context: AppContext
    let container: DependencyContainer
    let conflictReference: UUID?
    /// R.5Z.fix.1 — callback con decision_id post-create. El parent
    /// (CreateIntentSheet) dismissea + pushea al DecisionDetailView creado.
    var onCreated: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var store: DecisionsStore
    @State private var title: String
    @State private var description = ""
    @State private var decisionType: DecisionType
    @State private var votingModel: VotingModel
    @State private var optionDrafts: [DecisionOptionDraft] = []
    @State private var newOptionText: String = ""
    /// R.4B — plantilla seleccionada (nil = decisión libre). Las plantillas
    /// `coming_soon` se pueden elegir pero el submit queda deshabilitado.
    @State private var selectedTemplateKey: String?
    /// R.4B — valores crudos del form de payload, por nombre de campo.
    @State private var formText: [String: String] = [:]
    @State private var runner = ActionRunner()
    /// R.6.AI.8 — AI hero state.
    @State private var suggestionService = DecisionSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []

    public init(
        context: AppContext,
        container: DependencyContainer,
        prefilledTitle: String = "",
        prefilledType: DecisionType = .generic,
        conflictReference: UUID? = nil,
        onCreated: ((UUID) -> Void)? = nil
    ) {
        self.context = context
        self.container = container
        self.conflictReference = conflictReference
        self.onCreated = onCreated
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
            // R.6.AI.8 — Hero AI sólo cuando no viene de un conflicto pre-poblado
            // ni de una plantilla (la plantilla ya estructura la decisión).
            if conflictReference == nil && selectedTemplate == nil {
                aiHero
            }

            // R.4B — picker de plantillas (no aplica a disputas de reservación).
            if conflictReference == nil {
                templateSection
            }

            Section("Propuesta") {
                TextField("¿Qué hay que decidir?", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Contexto o detalles (opcional)", text: $description, axis: .vertical)
                    .lineLimit(2...5)
            }

            if let template = selectedTemplate {
                templateBody(template)
            } else {
                freeFormBody
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
        .task {
            if conflictReference == nil {
                await store.loadCreateCatalog(context: context)
            }
        }
        .actionErrorAlert(runner)
        .ruulSheet()
    }

    // MARK: - Free-form (R.2Q) — sin plantilla

    @ViewBuilder
    private var freeFormBody: some View {
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
    }

    // MARK: - R.4B — Plantillas

    /// Plantilla seleccionada resuelta desde el catálogo cargado.
    private var selectedTemplate: DecisionTemplate? {
        guard let key = selectedTemplateKey else { return nil }
        return store.templates.first { $0.templateKey == key }
    }

    /// Plantillas ofrecidas en el picker: solo las ejecutables, alfabéticas.
    /// `reservation_award` se excluye (entra por flujo de conflicto, F.9).
    /// R.13.A (founder lock 2026-06-16) — antes ofrecíamos también las
    /// `coming_soon` con badge "Próximamente"; doctrina "nada que no tenga
    /// que estar" elimina ese branch. Cuando una plantilla nueva esté
    /// ejecutable backend, aparece automáticamente.
    private var offeredTemplates: [DecisionTemplate] {
        store.templates
            .filter { !$0.isReservationAward && $0.isExecutable }
            .sorted { $0.displayName < $1.displayName }
    }

    @ViewBuilder
    private var templateSection: some View {
        if !offeredTemplates.isEmpty {
            Section {
                Picker("Plantilla", selection: $selectedTemplateKey) {
                    Text("Sin plantilla (libre)").tag(String?.none)
                    ForEach(offeredTemplates) { template in
                        Text(template.displayName)
                            .tag(Optional(template.templateKey))
                    }
                }
                .pickerStyle(.navigationLink)
                .onChange(of: selectedTemplateKey) { _, _ in onTemplateChange() }
            } header: {
                Text("Plantilla")
            } footer: {
                Text("Las plantillas estructuran la decisión y ejecutan su efecto al aprobarse. Déjala en «libre» para una decisión sin plantilla.")
            }
        }
    }

    /// Cuerpo dependiente de la plantilla: descripción, form de payload (si
    /// aplica), y el modo de votación heredado. Las plantillas `coming_soon`
    /// se filtran del picker (offeredTemplates), nunca llegan aquí.
    @ViewBuilder
    private func templateBody(_ template: DecisionTemplate) -> some View {
        if let detail = template.description {
            Section { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }

        if template.hasPayloadForm {
            templateFormSection(template)
        }

        Section {
            LabeledContent("Modo de votación", value: template.voting.label)
        } footer: {
            Text("Heredado de la plantilla. Se aprueba con mayoría simple.")
        }
    }

    @ViewBuilder
    private func templateFormSection(_ template: DecisionTemplate) -> some View {
        Section {
            ForEach(template.payloadSchema.fields) { field in
                templateField(field)
            }
        } header: {
            Text("Parámetros")
        } footer: {
            Text("Define el objeto de la decisión. Estos valores se aplican cuando se aprueba.")
        }
    }

    @ViewBuilder
    private func templateField(_ field: DecisionTemplatePayloadSchema.Field) -> some View {
        let label = fieldLabel(field)
        switch field.name {
        case "resource_id":
            Picker(label, selection: bindingFor(field.name)) {
                Text("Selecciona…").tag("")
                ForEach(store.resources) { resource in
                    Text(resource.displayName).tag(resource.resourceId.uuidString)
                }
            }
            .pickerStyle(.navigationLink)
        case "rule_id":
            Picker(label, selection: bindingFor(field.name)) {
                Text("Selecciona…").tag("")
                ForEach(store.rules) { rule in
                    Text(rule.title).tag(rule.id.uuidString)
                }
            }
            .pickerStyle(.navigationLink)
        case "holder_actor_id":
            Picker(label, selection: bindingFor(field.name)) {
                Text("Selecciona…").tag("")
                ForEach(store.members) { member in
                    Text(member.displayName).tag(member.actorId.uuidString)
                }
            }
            .pickerStyle(.navigationLink)
        case "right_kind":
            Picker(label, selection: bindingFor(field.name)) {
                Text("Selecciona…").tag("")
                ForEach(RightKind.allCases) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.navigationLink)
        case "percent":
            TextField(label, text: bindingFor(field.name))
                .keyboardType(.decimalPad)
        default:
            TextField(label, text: bindingFor(field.name))
        }
    }

    private func bindingFor(_ fieldName: String) -> Binding<String> {
        Binding(
            get: { formText[fieldName] ?? "" },
            set: { formText[fieldName] = $0 }
        )
    }

    private func fieldLabel(_ field: DecisionTemplatePayloadSchema.Field) -> String {
        let base: String
        switch field.name {
        case "resource_id": base = "Recurso"
        case "rule_id": base = "Regla"
        case "holder_actor_id": base = "Beneficiario"
        case "right_kind": base = "Derecho"
        case "percent": base = "Porcentaje (%)"
        case "scope": base = "Alcance"
        case "reason": base = "Motivo"
        case "description": base = "Descripción"
        default: base = field.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return field.required ? base : "\(base) (opcional)"
    }

    /// Al cambiar de plantilla limpiamos el form y prefilleamos el título con
    /// el nombre de la plantilla si el usuario aún no escribió nada.
    private func onTemplateChange() {
        formText = [:]
        if let template = selectedTemplate,
           title.trimmingCharacters(in: .whitespaces).isEmpty {
            title = template.displayName
        }
    }

    /// Valores no vacíos del form, convertidos a JSONValue por tipo.
    private var collectedFormValues: [String: JSONValue] {
        guard let template = selectedTemplate else { return [:] }
        var values: [String: JSONValue] = [:]
        for field in template.payloadSchema.fields {
            let raw = (formText[field.name] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            switch field.kind {
            case .numeric:
                if let n = Double(raw) { values[field.name] = .number(n) }
            default:
                values[field.name] = .string(raw)
            }
        }
        return values
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

    /// 7.C.2 (audit 2026-06-14) — hint específico por modo + ejemplo
    /// concreto. Antes el usuario veía solo la primera frase sin saber
    /// cuándo conviene cada modo.
    private var votingModelHint: String {
        switch votingModel {
        case .yesNoAbstain:
            return "Cada miembro vota a favor, en contra o abstención. Ideal para preguntas simples como \"¿subimos la cuota?\"."
        case .singleChoice:
            return "Cada miembro elige una opción de las que definas abajo. Ideal para elegir entre alternativas, como \"¿a dónde vamos de viaje?\"."
        case .multipleChoice:
            return "Cada miembro puede elegir varias opciones a la vez. Ideal para priorizar, como \"¿qué actividades te interesan?\". El cierre es manual."
        default:
            return ""
        }
    }

    private var canSubmit: Bool {
        let titleOK = !title.trimmingCharacters(in: .whitespaces).isEmpty
        guard titleOK else { return false }
        // R.4B — con plantilla: las `coming_soon` no se pueden proponer; las
        // ejecutables exigen sus campos `required`.
        if let template = selectedTemplate {
            guard template.isExecutable else { return false }
            return template.missingRequiredFields(in: collectedFormValues).isEmpty
        }
        if (votingModel == .singleChoice || votingModel == .multipleChoice) && conflictReference == nil {
            return optionDrafts.count >= 2
        }
        return true
    }

    private var submitFooter: String {
        if let template = selectedTemplate {
            if template.isComingSoon {
                return "Esta plantilla aún no está disponible para proponerse."
            }
            return "Se aprueba con mayoría simple. Al ejecutarse aplica el efecto de «\(template.displayName)»."
        }
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

    // MARK: - R.6.AI.8 — AI hero

    private var aiHero: some View {
        RuulAIHeroView(
            headline: "Pídele a Ruul",
            subtitle: "Describe la decisión y la armamos por ti",
            placeholder: "Ej: ¿Compramos el coche nuevo?",
            ctaLabel: "Pensar decisión",
            examples: [
                "¿Compramos el coche nuevo?",
                "Cambiar la cena al sábado",
                "Aprobar el gasto del palco",
                "Subir la cuota mensual"
            ],
            footerWhenIdle: "Descríbela con tus palabras o escribe el título manualmente.",
            footerWhenLoaded: "La decisión ya está armada abajo. Ajústala si quieres.",
            prompt: $aiPromptText,
            considered: $lastConsidered,
            phase: aiPhase,
            onSuggest: { await aiSuggest() },
            onReset: {
                lastConsidered = []
                aiPromptText = ""
                suggestionService.reset()
            }
        )
    }

    private var aiPhase: RuulAIHeroView.HeroPhase {
        switch suggestionService.phase {
        case .idle, .loaded: return .idle
        case .loading:       return .loading
        case .failed(let m): return .failed(message: m)
        case .unavailable(let r): return .unavailable(reason: r)
        }
    }

    private func aiSuggest() async {
        await suggestionService.suggest(
            prompt: aiPromptText,
            rpc: container.rpc,
            contextId: context.id
        )
        if case .loaded(let suggestion, let considered) = suggestionService.phase {
            applyAISuggestion(suggestion)
            lastConsidered = considered
            suggestionService.reset()
        }
    }

    private func applyAISuggestion(_ s: DecisionSuggestion) {
        if !s.title.isEmpty { title = s.title }
        if !s.detail.isEmpty { description = s.detail }
        // decisionKind se mantiene manual por ahora — el VotingModel canónico
        // de Ruul no mapea 1:1 a unanimous/two_thirds. El user lo elige abajo.
    }

    private func create() async {
        var createdId: UUID?
        let success = await runner.run {
            // R.4B — flujo de plantilla: el backend hereda voting model y
            // despacha el efecto al ejecutar según `execution_kind`.
            if let template = selectedTemplate {
                let values = collectedFormValues
                let input = CreateDecisionInput(
                    contextId: context.id,
                    decisionType: .generic,
                    title: title.trimmingCharacters(in: .whitespaces),
                    description: description.isEmpty ? nil : description,
                    payload: values.isEmpty ? nil : .object(values),
                    clientId: UUID().uuidString,
                    votingModel: nil,
                    templateKey: template.templateKey,
                    decisionTypeRaw: template.decisionType
                )
                let created = try await store.createDecision(input, context: context)
                createdId = created.id
                return
            }

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
                let created = try await store.createDecision(input, options: optionDrafts, context: context)
                createdId = created.id
            } else {
                let created = try await store.createDecision(input, context: context)
                createdId = created.id
            }
        }
        if success {
            if let id = createdId, let onCreated {
                onCreated(id)
            } else {
                dismiss()
            }
        }
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
