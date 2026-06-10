import SwiftUI
import RuulCore

/// Subtype Picker · UX D — flow founder-firmado 2026-06-07.
///
/// Reemplaza el legacy `CreateResourceView` (Form con Picker de `resource_type`)
/// por un wizard de 3 pasos:
///
/// ```
/// Step 1  ClassPickerView      — 17 classes (Apple HIG: List + grouped + chevron)
/// Step 2  SubtypePickerView    — subtypes filtrados por class (skip si 1 subtype)
/// Step 3  CreateResourceForm   — form con class+subtype prellenados
/// ```
///
/// **Founder rationale literal:** *"el subtype es parte del modelo central
/// de Ruul; el estilo visual puede esperar unas semanas más"*. R.6 Rule Engine
/// depende de subtype correcto en TODOS los resources nuevos.
public struct CreateResourceFlow: View {
    let context: AppContext
    let container: DependencyContainer
    let store: ResourcesStore

    public init(context: AppContext, store: ResourcesStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            ClassPickerView(context: context, container: container, store: store)
        }
        .ruulSheet()
    }
}

// MARK: - Step 1: Class picker

private struct ClassPickerView: View {
    let context: AppContext
    let container: DependencyContainer
    let store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var classes: [ResourceClass] = []
    @State private var phase: StorePhase = .idle
    /// R.6.AI.13 — AI hero state.
    @State private var suggestionService = ResourceSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []
    /// Resultado de la resolución AI: classRef + subtype + prefilled. Cuando
    /// no es nil, se presenta el form como sheet.
    @State private var aiResolved: AIResolvedResource?

    struct AIResolvedResource: Identifiable {
        let id = UUID()
        let classRef: ResourceClass
        let subtype: ResourceSubtype
        let suggestion: ResourceSuggestion
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando categorías…")
            case .failed(let message):
                RuulErrorState(message: message) { Task { await load() } }
            case .loaded:
                List {
                    aiHero
                    Section("Categorías") {
                        ForEach(classes) { cls in
                            NavigationLink(value: Route.subtype(cls)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cls.displayName)
                                        if let description = cls.description {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundStyle(Theme.Text.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: cls.icon ?? "tag.fill")
                                        .foregroundStyle(Theme.Tint.primary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Nuevo recurso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { dismiss() }
            }
        }
        .task { await load() }
        // R.6.AI.13 — sheet con el form prerellenado cuando AI resolvió.
        .sheet(item: $aiResolved) { resolved in
            NavigationStack {
                CreateResourceForm(
                    classRef: resolved.classRef,
                    subtype: resolved.subtype,
                    context: context,
                    container: container,
                    store: store,
                    prefilled: resolved.suggestion
                )
            }
        }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .subtype(let cls):
                SubtypePickerView(classRef: cls, context: context, container: container, store: store)
            case .form(let cls, let subtype):
                CreateResourceForm(classRef: cls, subtype: subtype, context: context, container: container, store: store)
            }
        }
    }

    private func load() async {
        if classes.isEmpty { phase = .loading }
        do {
            classes = try await container.rpc.listResourceClasses()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Rutas internas del flow (Hashable para navigationDestination).
    enum Route: Hashable {
        case subtype(ResourceClass)
        case form(ResourceClass, ResourceSubtype)
    }

    // MARK: - R.6.AI.13 — AI Hero

    private var aiHero: some View {
        RuulAIHeroView(
            headline: "Pídele a Ruul",
            subtitle: "Describe el recurso y elegimos la categoría por ti",
            placeholder: "Ej: Casa Valle en San Miguel, vale 5M",
            ctaLabel: "Pensar recurso",
            examples: [
                "Casa Valle en San Miguel, vale 5M",
                "Fondo común BBVA",
                "Camioneta Toyota Hilux",
                "Boletos del Mundial"
            ],
            footerWhenIdle: "Descríbelo con tus palabras o elige una categoría abajo.",
            footerWhenLoaded: "Abrimos el form con todo armado en cuanto resolvamos la categoría.",
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
        guard case .loaded(let suggestion, let considered) = suggestionService.phase else { return }
        lastConsidered = considered
        // Resolve class del taxonomy ya cargado.
        guard let cls = classes.first(where: { $0.classKey == suggestion.classKey })
            ?? classes.first(where: { $0.classKey == "generic_other" }) else {
            suggestionService.reset()
            return
        }
        // Fetch subtypes del class elegido y resuelve por subtypeKey hint.
        do {
            let subtypes = try await container.rpc.listResourceSubtypes(classKey: cls.classKey)
            let subtype = subtypes.first(where: { $0.subtypeKey == suggestion.subtypeKey })
                ?? subtypes.first(where: { $0.subtypeKey.hasPrefix("generic") })
                ?? subtypes.first
            guard let subtype else {
                suggestionService.reset()
                return
            }
            aiResolved = AIResolvedResource(classRef: cls, subtype: subtype, suggestion: suggestion)
            suggestionService.reset()
        } catch {
            // Subtype fetch falló — quedó en idle, user puede tap manualmente.
            suggestionService.reset()
        }
    }
}

// MARK: - Step 2: Subtype picker

private struct SubtypePickerView: View {
    let classRef: ResourceClass
    let context: AppContext
    let container: DependencyContainer
    let store: ResourcesStore

    @State private var subtypes: [ResourceSubtype] = []
    @State private var phase: StorePhase = .idle
    @State private var autoSkippedToForm: Bool = false

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando subtipos…")
            case .failed(let message):
                RuulErrorState(message: message) { Task { await load() } }
            case .loaded:
                if subtypes.count == 1 && !autoSkippedToForm {
                    // 11 classes tienen sólo 1 "generic" subtype — auto-skip step 2.
                    autoSkip(to: subtypes[0])
                } else {
                    List(subtypes) { subtype in
                        NavigationLink(value: ClassPickerView.Route.form(classRef, subtype)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subtype.displayName)
                                if let description = subtype.description {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle(classRef.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if subtypes.isEmpty { phase = .loading }
        do {
            subtypes = try await container.rpc.listResourceSubtypes(classKey: classRef.classKey)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    @ViewBuilder
    private func autoSkip(to subtype: ResourceSubtype) -> some View {
        // Único subtype — push directo a form sin pasar por picker.
        RuulLoadingState(title: "Abriendo…")
            .navigationDestination(isPresented: .constant(true)) {
                CreateResourceForm(classRef: classRef, subtype: subtype, context: context, container: container, store: store)
            }
    }
}

// MARK: - Step 3: Form (refactor del legacy CreateResourceView)

private struct CreateResourceForm: View {
    let classRef: ResourceClass
    let subtype: ResourceSubtype
    let context: AppContext
    let container: DependencyContainer
    let store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var descriptionText: String
    @State private var hasValue: Bool
    @State private var estimatedValue: String
    @State private var currency: String
    @State private var locationText: String
    @State private var runner = ActionRunner()
    @State private var guardCandidates: [ResourceCreationCandidate] = []

    /// R.6.AI.13 — Init que acepta prefilled de AI (default empty fields).
    init(
        classRef: ResourceClass,
        subtype: ResourceSubtype,
        context: AppContext,
        container: DependencyContainer,
        store: ResourcesStore,
        prefilled: ResourceSuggestion? = nil
    ) {
        self.classRef = classRef
        self.subtype = subtype
        self.context = context
        self.container = container
        self.store = store
        _displayName = State(initialValue: prefilled?.displayName ?? "")
        _descriptionText = State(initialValue: prefilled?.detail ?? "")
        _hasValue = State(initialValue: (prefilled?.estimatedValue ?? 0) > 0)
        _estimatedValue = State(
            initialValue: (prefilled?.estimatedValue ?? 0) > 0
                ? String(format: "%g", prefilled?.estimatedValue ?? 0)
                : ""
        )
        _currency = State(
            initialValue: (prefilled?.currency.isEmpty ?? true)
                ? "MXN"
                : (prefilled?.currency.uppercased() ?? "MXN")
        )
        _locationText = State(initialValue: prefilled?.locationText ?? "")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Categoría", value: classRef.displayName)
                LabeledContent("Subtipo", value: subtype.displayName)
            } footer: {
                if let description = subtype.description {
                    Text(description)
                }
            }

            Section("Recurso") {
                TextField("Nombre (Casa Valle, Fondo común…)", text: $displayName)
                TextField("Descripción (opcional)", text: $descriptionText, axis: .vertical)
                    .lineLimit(2...4)
            }

            CreationGuardView(
                candidates: guardCandidates.map(CreationGuardCandidate.from)
            ) { _ in
                dismiss()
            }

            Section("Ubicación") {
                TextField("Dirección o lugar (opcional)", text: $locationText)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }

            Section("Valor estimado") {
                Toggle("Tiene valor estimado", isOn: $hasValue)
                if hasValue {
                    TextField("Monto", text: $estimatedValue)
                        .keyboardType(.decimalPad)
                    TextField("Moneda", text: $currency)
                        .textInputAutocapitalization(.characters)
                }
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    if runner.isRunning {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Crear recurso").frame(maxWidth: .infinity)
                    }
                }
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
            } footer: {
                Text("\(context.displayName) queda como dueño (OWN 100%). Después puedes otorgar derechos de uso a miembros u otros contextos.")
            }
        }
        .navigationTitle("Nuevo \(subtype.displayName.lowercased())")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: displayName) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            let trimmed = displayName.trimmingCharacters(in: .whitespaces)
            guard !Task.isCancelled, trimmed.count >= 3 else {
                if trimmed.count < 3 { guardCandidates = [] }
                return
            }
            do {
                guardCandidates = try await container.rpc.resourceCreationCandidates(
                    displayName: trimmed,
                    contextId: context.id
                )
            } catch {
                guardCandidates = []
            }
        }
        .actionErrorAlert(runner)
    }

    private func create() async {
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            _ = try await store.createResource(
                CreateResourceInput(
                    contextId: context.id,
                    // resource_type legacy queda como fallback — backend deriva del subtype.
                    resourceTypeKey: "other",
                    displayName: displayName.trimmingCharacters(in: .whitespaces),
                    description: descriptionText.isEmpty ? nil : descriptionText,
                    estimatedValue: hasValue ? Double(estimatedValue) : nil,
                    currency: hasValue ? currency : nil,
                    locationText: trimmedLocation.isEmpty ? nil : trimmedLocation,
                    clientId: UUID().uuidString,
                    subtypeKey: subtype.subtypeKey
                ),
                context: context
            )
        }
        if success { dismiss() }
    }
}
