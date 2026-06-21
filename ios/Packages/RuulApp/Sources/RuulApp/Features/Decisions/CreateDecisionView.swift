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

    // R.5Z.fix.9 D.PICKER — decisiones target-scoped vía request_governance_action.
    // Founder smoke 2026-06-09 Flow #9: "las decisiones están desconectadas
    // del modelo. Debería poder decidir sobre contextos, recursos, miembros,
    // reglas, eventos, etc."
    /// Sobre qué decidir. `.free` mantiene comportamiento legacy (create_decision).
    /// Los demás disparan `request_governance_action(action_key, target_type, target_id)`.
    @State private var target: DecisionTarget = .free
    @State private var selectedEntityId: UUID?
    @State private var selectedEntityName: String = ""
    @State private var selectedActionKey: String?
    @State private var selectedActionLabel: String = ""
    /// Cargado on first appear desde `governance_action_catalog`. Compartido
    /// con MemberDetailView etc. — solo lectura.
    @State private var catalogEntries: [GovernanceCatalogEntry] = []
    @State private var governanceClientId: String = UUID().uuidString

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
            // R.5Z.fix.9 D.PICKER — picker "¿Sobre qué decidir?" arriba.
            // Disputas de reservación llegan pre-pobladas como .free.
            if conflictReference == nil {
                targetSection
            }

            if target == .free {
                // R.6.AI.8 — Hero AI sólo cuando no viene de un conflicto
                // pre-poblado ni de una plantilla (la plantilla ya estructura
                // la decisión).
                if conflictReference == nil && selectedTemplate == nil {
                    aiHero
                }

                // R.4B — picker de plantillas (no aplica a disputas).
                if conflictReference == nil {
                    templateSection
                }

                Section("Propuesta") {
                    TextField("¿Qué hay que decidir?", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Detalles opcionales", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let template = selectedTemplate {
                    templateBody(template)
                } else {
                    freeFormBody
                }
            } else {
                // R.5Z.fix.9 — target-scoped: entity picker + action picker.
                entitySection
                if selectedEntityId != nil {
                    actionSection
                }
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
        .navigationTitle("Nueva votación")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
        }
        .task {
            if conflictReference == nil {
                await store.loadCreateCatalog(context: context)
                await loadGovernanceCatalog()
            }
        }
        .actionErrorAlert(runner)
        .ruulSheet()
    }

    // MARK: - R.5Z.fix.9 D.PICKER — target picker

    @ViewBuilder
    private var targetSection: some View {
        Section {
            Picker("Sobre qué decidir", selection: $target) {
                ForEach(DecisionTarget.allCases) { t in
                    Label(t.label, systemImage: t.symbolName).tag(t)
                }
            }
            .pickerStyle(.navigationLink)
            .onChange(of: target) { _, _ in
                // Reset entity + action al cambiar target.
                selectedEntityId = nil
                selectedEntityName = ""
                selectedActionKey = nil
                selectedActionLabel = ""
                governanceClientId = UUID().uuidString
            }
        } header: {
            Text("¿Sobre qué decidir?")
        } footer: {
            Text(target.helpText)
        }
    }

    @ViewBuilder
    private var entitySection: some View {
        Section {
            NavigationLink {
                EntityPickerView(
                    target: target,
                    context: context,
                    container: container,
                    onPick: { id, name in
                        selectedEntityId = id
                        selectedEntityName = name
                        selectedActionKey = nil
                        selectedActionLabel = ""
                    }
                )
            } label: {
                LabeledContent(target.entityLabel) {
                    Text(selectedEntityName.isEmpty ? "Elegir…" : selectedEntityName)
                        .foregroundStyle(selectedEntityName.isEmpty ? Theme.Text.tertiary : Theme.Text.primary)
                }
            }
        } header: {
            Text(target.entityLabel)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            NavigationLink {
                ActionPickerView(
                    target: target,
                    catalog: filteredCatalog,
                    onPick: { actionKey, label in
                        selectedActionKey = actionKey
                        selectedActionLabel = label
                    }
                )
            } label: {
                LabeledContent("Acción") {
                    Text(selectedActionLabel.isEmpty ? "Elegir…" : selectedActionLabel)
                        .foregroundStyle(selectedActionLabel.isEmpty ? Theme.Text.tertiary : Theme.Text.primary)
                }
            }
        } header: {
            Text("Acción a proponer")
        } footer: {
            if !selectedActionLabel.isEmpty {
                Text("Ruul abrirá una votación para aprobar esta acción sobre \(selectedEntityName).")
            }
        }
    }

    private var filteredCatalog: [GovernanceCatalogEntry] {
        catalogEntries.filter { entry in
            target.matches(actionKey: entry.actionKey)
        }
    }

    private func loadGovernanceCatalog() async {
        if !catalogEntries.isEmpty { return }
        do {
            catalogEntries = try await container.rpc.listGovernanceActionCatalog()
        } catch {
            // Fail silently — el picker se queda vacío y user vuelve a .free.
            catalogEntries = []
        }
    }

    // MARK: - Free-form (R.2Q) — sin plantilla

    @ViewBuilder
    private var freeFormBody: some View {
        // Avanzado: Tipo + Modo de votación. El 95% de los usuarios deja los
        // defaults (yes_no_abstain / generic); colapsarlos en un DisclosureGroup
        // mantiene el camino corto rápido y los hace accesibles para quien los
        // necesita. En conflictos pre-poblados el modo es fijo — saltamos el
        // wrapper entero y mostramos sólo el Tipo (legacy behavior).
        if conflictReference == nil {
            Section {
                DisclosureGroup {
                    Picker("Tipo", selection: $decisionType) {
                        ForEach(DecisionType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Modo de votación", selection: $votingModel) {
                        ForEach(supportedVotingModels, id: \.self) { model in
                            Text(model.label).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } label: {
                    Label("Avanzado", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                }
            } footer: {
                Text(votingModelHint)
            }
        } else {
            Section("Tipo") {
                Picker("Tipo", selection: $decisionType) {
                    ForEach(DecisionType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.navigationLink)
            }
        }

        // R.2Q — opciones manuales para single_choice y multiple_choice no-disputa.
        // Aparece automáticamente cuando el usuario cambia el modo dentro del
        // DisclosureGroup Avanzado.
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
                Text("Las plantillas estructuran la votación y aplican su efecto al aprobarse. Déjala en «libre» para una votación sin plantilla.")
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
            Text("Define los datos de la votación. Estos valores se aplican cuando se aprueba.")
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
        case "resource_id": base = "Cosa"
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
        // R.5Z.fix.9 — target-scoped requiere entity + action (NO title manual).
        if target != .free {
            return selectedEntityId != nil && selectedActionKey != nil
        }
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
        // R.5Z.fix.9 — target-scoped flow vía request_governance_action.
        if target != .free {
            if selectedActionKey == nil {
                return "Elige la acción que quieres proponer."
            }
            return "Se abre una votación para aprobar la acción sobre \(selectedEntityName). Se usará la mayoría configurada del grupo."
        }
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
            subtitle: "Describe la votación y la armamos por ti",
            placeholder: "Ej: ¿Compramos el coche nuevo?",
            ctaLabel: "Pensar votación",
            examples: [
                "¿Compramos el coche nuevo?",
                "Cambiar la cena al sábado",
                "Aprobar el gasto del palco",
                "Subir la cuota mensual"
            ],
            footerWhenIdle: "Descríbela con tus palabras o escribe el título manualmente.",
            footerWhenLoaded: "La votación ya está armada abajo. Ajústala si quieres.",
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
            // R.5Z.fix.9 D.PICKER — target-scoped: request_governance_action
            // crea la decisión + el governance_action atados via decision_id.
            // El backend exige la mayoría definida por la policy del contexto.
            if target != .free, let actionKey = selectedActionKey, let entityId = selectedEntityId {
                let input = RequestGovernanceActionInput(
                    contextActorId: context.id,
                    actionKey: actionKey,
                    targetType: target.governanceTargetType,
                    targetId: entityId,
                    payload: .object([:]),
                    title: "\(selectedActionLabel): \(selectedEntityName)",
                    closesAt: nil,
                    clientId: governanceClientId
                )
                let result = try await container.rpc.requestGovernanceAction(input)
                // Si abrió una decisión, push al detail; si no, dismiss.
                createdId = result.decisionId
                return
            }
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

// MARK: - R.5Z.fix.9 D.PICKER — DecisionTarget enum

/// Sobre qué decidir. `.free` mantiene comportamiento legacy (`create_decision`
/// directo). Los demás disparan `request_governance_action(actionKey,
/// targetType, targetId)` y el backend abre la decisión atada via
/// `governance_actions.decision_id`.
enum DecisionTarget: String, CaseIterable, Identifiable, Hashable {
    case free, member, resource, rule

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:     return "Pregunta libre"
        case .member:   return "Un miembro"
        case .resource: return "Una cosa"
        case .rule:     return "Una regla"
        }
    }

    var symbolName: String {
        switch self {
        case .free:     return "questionmark.bubble"
        case .member:   return "person.crop.circle"
        case .resource: return "shippingbox.fill"
        case .rule:     return "scroll"
        }
    }

    var helpText: String {
        switch self {
        case .free:
            return "Cualquier propuesta sin objetivo específico (compra, cambio, evento futuro)."
        case .member:
            return "Promover, pausar o remover a alguien del grupo."
        case .resource:
            return "Transferir, archivar o cambiar acceso sobre una cosa del grupo."
        case .rule:
            return "Archivar una regla automática del grupo."
        }
    }

    var entityLabel: String {
        switch self {
        case .free:     return ""
        case .member:   return "Miembro"
        case .resource: return "Cosa"
        case .rule:     return "Regla"
        }
    }

    /// Mapea a `governance_actions.target_type` que `request_governance_action`
    /// espera. R.7.x.iOS shipped usa estos exactos strings.
    var governanceTargetType: String {
        switch self {
        case .free:     return ""
        case .member:   return "member"
        case .resource: return "resource"
        case .rule:     return "rule"
        }
    }

    /// Verifica si un `action_key` del catalog aplica a este target.
    func matches(actionKey: String) -> Bool {
        switch self {
        case .free:     return false
        case .member:   return actionKey.hasPrefix("member.")
        case .resource: return actionKey.hasPrefix("resource.")
        case .rule:     return actionKey.hasPrefix("rule.")
        }
    }
}

// MARK: - R.5Z.fix.9 — Entity picker

/// Lista las entidades del contexto correspondientes al target_type elegido.
/// Tap → callback con `(entityId, displayName)` y pop al CreateDecisionView.
private struct EntityPickerView: View {
    let target: DecisionTarget
    let context: AppContext
    let container: DependencyContainer
    let onPick: (UUID, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: StorePhase = .idle
    @State private var members: [ContextMember] = []
    @State private var resources: [ContextResource] = []
    @State private var rules: [Rule] = []
    @State private var query: String = ""

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) { Task { await load() } }
            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Elige \(target.entityLabel.lowercased())")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var loadedContent: some View {
        switch target {
        case .free:
            EmptyView()
        case .member:
            memberList
        case .resource:
            resourceList
        case .rule:
            ruleList
        }
    }

    @ViewBuilder
    private var memberList: some View {
        if members.isEmpty {
            RuulEmptyState(title: "Sin miembros", systemImage: "person.2", message: "No hay miembros activos en este grupo.")
        } else {
            List {
                ForEach(filteredMembers) { m in
                    Button {
                        onPick(m.actorId, m.displayName)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ActorInitialsView(name: m.displayName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName).font(.callout.weight(.medium))
                                Text(m.isInvited ? "Invitación pendiente" : (m.isAdmin ? "Administrador" : "Miembro"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar miembro")
        }
    }

    @ViewBuilder
    private var resourceList: some View {
        if resources.isEmpty {
            RuulEmptyState(title: "Sin cosas", systemImage: "shippingbox", message: "Este grupo no tiene cosas registradas aún.")
        } else {
            List {
                ForEach(filteredResources) { r in
                    Button {
                        onPick(r.resourceId, r.displayName)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: r.type.symbolName)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.displayName).font(.callout.weight(.medium))
                                Text(r.type.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar cosa")
        }
    }

    @ViewBuilder
    private var ruleList: some View {
        if rules.isEmpty {
            RuulEmptyState(title: "Sin reglas", systemImage: "scroll", message: "Este grupo no tiene reglas activas.")
        } else {
            List {
                ForEach(filteredRules) { rule in
                    Button {
                        onPick(rule.id, rule.title)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "scroll")
                                .foregroundStyle(Theme.Tint.warning)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title).font(.callout.weight(.medium))
                                if let trigger = rule.triggerEventType {
                                    Text(trigger).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar regla")
        }
    }

    private var filteredMembers: [ContextMember] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { $0.displayName.lowercased().contains(q) }
    }

    private var filteredResources: [ContextResource] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return resources }
        return resources.filter { $0.displayName.lowercased().contains(q) }
    }

    private var filteredRules: [Rule] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rules }
        return rules.filter { $0.title.lowercased().contains(q) }
    }

    private func load() async {
        if members.isEmpty && resources.isEmpty && rules.isEmpty { phase = .loading }
        do {
            switch target {
            case .member:
                let summary = try await container.rpc.contextSummary(contextId: context.id)
                members = summary.members.filter { !$0.isInvited }
            case .resource:
                resources = try await container.rpc.listContextResources(contextId: context.id)
            case .rule:
                rules = try await container.rpc.listRules(contextId: context.id)
            case .free:
                break
            }
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}

// MARK: - R.5Z.fix.9 — Action picker

/// Lista las acciones del `governance_action_catalog` filtradas por target_type.
/// Tap → callback con `(actionKey, displayName)` y pop al CreateDecisionView.
private struct ActionPickerView: View {
    let target: DecisionTarget
    let catalog: [GovernanceCatalogEntry]
    let onPick: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if catalog.isEmpty {
                RuulEmptyState(
                    title: "Sin acciones",
                    systemImage: "questionmark.circle",
                    message: "No hay acciones del catalog que apliquen a \(target.entityLabel.lowercased())."
                )
            } else {
                List {
                    ForEach(catalog) { entry in
                        Button {
                            onPick(entry.actionKey, entry.displayName)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.dangerous ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                    .foregroundStyle(entry.dangerous ? Theme.Tint.critical : Theme.Tint.primary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName).font(.callout.weight(.medium))
                                    Text(entry.actionKey).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Acción")
        .navigationBarTitleDisplayMode(.inline)
    }
}
