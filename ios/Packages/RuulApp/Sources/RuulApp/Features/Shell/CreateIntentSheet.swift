import SwiftUI
import RuulCore

/// F.NAV.5 — Sheet intent-first "¿Qué quieres hacer?".
///
/// Doctrina: el botón Crear NO expone primitivas. El usuario elige el espacio
/// arriba (picker inline) + qué quiere hacer (intent row). Tap directo al form
/// sin pantalla intermedia. El AI assistant vive en un DisclosureGroup al pie
/// para no competir con la lista principal.
public struct CreateIntentSheet: View {
    let container: DependencyContainer
    /// R.5Z.fix.1 — callback invocado cuando un flow de creación termina con
    /// éxito. La sheet se dismissea automáticamente; el shell parent presenta
    /// el `AttentionDestination` traducido como sheet siguiente (push al
    /// detail recién creado).
    let onCreated: ((AttentionDestination) -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// F.NAV.7+: el form (CreateEventView / RecordExpenseView / etc.) trae
    /// SU PROPIO NavigationStack interno. Anidarlo dentro del NavigationStack
    /// de la sheet crashea SwiftUI iOS 16+. Por eso presentamos el form como
    /// sheet anidado sobre la sheet de intent, no como push.
    @State private var pendingForm: PendingForm?
    /// F.NAV.8 — mismo problema con CreateContextView (NavigationStack
    /// interno). Sheet anidada también.
    @State private var isShowingCreateContext = false
    /// Override del contexto picker. Nil = usa `contextStore.currentContext`.
    @State private var pickedContextId: UUID?
    /// R.6.AI.2 — Detector de intent on-device. Graceful degradation si
    /// Apple Intelligence no está disponible.
    @State private var intentService = IntentSuggestionService()
    @State private var aiPromptText = ""

    public init(
        container: DependencyContainer,
        onCreated: ((AttentionDestination) -> Void)? = nil
    ) {
        self.container = container
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            List {
                contextPickerSection

                Section {
                    intentRow(.event,     icon: "calendar.badge.plus",     tint: .orange, label: "Programar algo",
                              detail: "Crear un evento del espacio.")
                    intentRow(.reservation, icon: "calendar.badge.clock",  tint: .orange, label: "Hacer reservación",
                              detail: "Reservar un recurso para unas fechas.")
                    intentRow(.expense,   icon: "dollarsign.circle.fill",  tint: .green,  label: "Registrar movimiento",
                              detail: "Anotar un gasto o ingreso.")
                    intentRow(.decision,  icon: "checkmark.bubble.fill",   tint: .purple, label: "Crear propuesta",
                              detail: "Abrir una decisión para votar.")
                    intentRow(.obligation, icon: "checklist",              tint: .indigo, label: "Asignar compromiso",
                              detail: "Pedir una acción, aprobación o entrega a alguien.")
                    intentRow(.document,  icon: "paperclip",               tint: .secondary, label: "Subir documento",
                              detail: "Adjuntar un archivo a un recurso.")
                    intentRow(.resource,  icon: "shippingbox.fill",        tint: .orange, label: "Agregar recurso",
                              detail: "Una casa, cuenta, vehículo o activo.")
                } header: {
                    Text("¿Qué quieres hacer?")
                        .font(.subheadline.weight(.semibold))
                }

                Section {
                    Button {
                        isShowingCreateContext = true
                    } label: {
                        intentLabel(icon: "rectangle.split.2x1.fill", tint: .blue,
                                    label: "Crear espacio",
                                    detail: "Una familia, viaje, proyecto, comunidad…")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Espacio nuevo")
                }

                aiIntentSection
            }
            .navigationTitle("Crear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task {
                await container.contextStore.load()
                await container.contextPreferencesStore.load()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // F.NAV.7+: form anidado como sheet sobre la sheet de intent.
        // Evita el crash de NavigationStack anidado (CreateEventView etc.
        // traen su propio NavigationStack interno).
        .sheet(item: $pendingForm) { form in
            FormDestination(
                intent: form.intent,
                context: form.context,
                container: container,
                onClose: {
                    pendingForm = nil
                    dismiss()
                },
                onCreated: { destination in
                    // R.5Z.fix.1 — entity creada: dismiss el form anidado +
                    // dismiss la sheet de intent + propagar destino al shell.
                    pendingForm = nil
                    dismiss()
                    onCreated?(destination)
                }
            )
        }
        // F.NAV.8 — CreateContextView también trae NavigationStack interno.
        .sheet(isPresented: $isShowingCreateContext) {
            CreateContextView(container: container, onCreated: { contextActorId, displayName in
                isShowingCreateContext = false
                dismiss()
                onCreated?(.context(contextActorId: contextActorId, contextDisplayName: displayName))
            })
        }
    }

    // MARK: - Context picker

    /// Contexto resuelto: override del picker > current del store. Nil si el
    /// store no ha cargado (raro post-RuulAppShell gates pero defensivo).
    private var pickedContext: AppContext? {
        if let id = pickedContextId,
           let match = container.contextStore.availableContexts.first(where: { $0.id == id }) {
            return match
        }
        return container.contextStore.currentContext
    }

    private var contextChoices: [AppContext] {
        let collectives = container.contextStore.availableContexts.filter { !$0.isPersonal }
        let personal = container.contextStore.availableContexts.filter { $0.isPersonal }
        return collectives + personal
    }

    @ViewBuilder
    private var contextPickerSection: some View {
        if let picked = pickedContext, contextChoices.count > 0 {
            Section {
                Menu {
                    Picker("Espacio", selection: Binding(
                        get: { picked.id },
                        set: { newId in
                            pickedContextId = newId
                            if let ctx = contextChoices.first(where: { $0.id == newId }) {
                                container.contextStore.switchTo(ctx)
                            }
                        }
                    )) {
                        ForEach(contextChoices) { ctx in
                            Text(ctx.isPersonal ? "Mi espacio" : ctx.displayName).tag(ctx.id)
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: picked.symbolName)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("En")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(picked.isPersonal ? "Mi espacio" : picked.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        if contextChoices.count > 1 {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(contextChoices.count <= 1)
            }
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func intentRow(_ intent: Intent, icon: String, tint: Color, label: String, detail: String) -> some View {
        Button {
            guard let ctx = pickedContext else { return }
            pendingForm = PendingForm(intent: intent, context: ctx)
        } label: {
            intentLabel(icon: icon, tint: tint, label: label, detail: detail)
        }
        .buttonStyle(.plain)
        .disabled(pickedContext == nil)
    }

    @ViewBuilder
    private func intentLabel(icon: String, tint: Color, label: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.badgeFillSubtle, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - R.6.AI.2 Smart Create Intent

    /// AI assistant colapsado al final. Sólo aparece cuando el servicio está
    /// disponible para no ofrecer un control inerte.
    @ViewBuilder
    private var aiIntentSection: some View {
        if intentService.isAvailable {
            Section {
                DisclosureGroup {
                    aiIntentBody
                } label: {
                    Label("Pregúntale a Ruul", systemImage: "sparkles")
                        .symbolRenderingMode(.hierarchical)
                        .font(.callout)
                }
            } footer: {
                Text("Describe lo que quieres hacer y Ruul propone una intención.")
            }
        }
    }

    @ViewBuilder
    private var aiIntentBody: some View {
        TextField(
            "Describe lo que quieres hacer…",
            text: $aiPromptText,
            axis: .vertical
        )
        .lineLimit(2...3)
        .disabled(isDetecting)

        switch intentService.phase {
        case .idle:
            Button {
                Task { await intentService.suggest(prompt: aiPromptText) }
            } label: {
                Label("Detectar intención", systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .frame(maxWidth: .infinity)
            }
            .disabled(aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .loading:
            HStack {
                ProgressView()
                Text("Detectando…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .loaded(let suggestion):
            detectedIntentPreview(suggestion)
        case .unavailable(let reason):
            Label(reason, systemImage: "sparkles.slash")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var isDetecting: Bool {
        if case .loading = intentService.phase { return true }
        return false
    }

    @ViewBuilder
    private func detectedIntentPreview(_ suggestion: IntentSuggestion) -> some View {
        if let intent = Intent(rawValueLoose: suggestion.intentKey) {
            VStack(alignment: .leading, spacing: 4) {
                Text(intentLabel(for: intent))
                    .font(.callout.weight(.semibold))
                Text(suggestion.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                guard let ctx = pickedContext else { return }
                intentService.reset()
                aiPromptText = ""
                pendingForm = PendingForm(intent: intent, context: ctx)
            } label: {
                Label("Continuar con \(intentLabel(for: intent).lowercased())", systemImage: "arrow.right.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .frame(maxWidth: .infinity)
            }
            .disabled(pickedContext == nil)
        } else {
            Label("No reconocí el intento. Intenta describirlo con otras palabras.", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Limpiar") {
                intentService.reset()
                aiPromptText = ""
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func intentLabel(for intent: Intent) -> String {
        switch intent {
        case .event:       return "Programar algo"
        case .expense:     return "Registrar movimiento"
        case .decision:    return "Crear propuesta"
        case .obligation:  return "Asignar compromiso"
        case .document:    return "Subir documento"
        case .resource:    return "Agregar recurso"
        case .reservation: return "Hacer reservación"
        }
    }

    // MARK: - Tipos

    enum Intent: Hashable {
        case event, expense, decision, document, resource, reservation, obligation

        /// R.6.AI.2 — mapeo desde el `intentKey` string del modelo on-device.
        /// Lowercase + trim para tolerar variantes (e.g., "Event", "events").
        init?(rawValueLoose raw: String) {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "event", "events":                       self = .event
            case "expense", "expenses":                   self = .expense
            case "decision", "decisions":                 self = .decision
            case "document", "documents":                 self = .document
            case "resource", "resources":                 self = .resource
            case "reservation", "reservations":           self = .reservation
            case "obligation", "obligations", "debt":     self = .obligation
            default:                                       return nil
            }
        }
    }

    /// Sheet anidada pendiente. `Identifiable` para `.sheet(item:)`.
    struct PendingForm: Identifiable {
        let id = UUID()
        let intent: Intent
        let context: AppContext
    }
}

// MARK: - Form destination

/// F.NAV.7+: conecta el intent + contexto al form real. Stores instanciados
/// EAGER via `@State` init constructor — el patrón lazy `.task + @State?` era
/// frágil cuando SwiftUI re-renderizaba el destino antes de que el task
/// completara, causando crashes intermitentes.
private struct FormDestination: View {
    let intent: CreateIntentSheet.Intent
    let context: AppContext
    let container: DependencyContainer
    let onClose: () -> Void
    /// R.5Z.fix.1 — invocado con el destino tipado al detail recién creado.
    /// El CreateIntentSheet propaga al shell para presentar como sheet.
    let onCreated: (AttentionDestination) -> Void

    @State private var eventsStore: EventsStore
    @State private var moneyStore: MoneyStore
    @State private var resourcesStore: ResourcesStore

    init(intent: CreateIntentSheet.Intent, context: AppContext, container: DependencyContainer, onClose: @escaping () -> Void, onCreated: @escaping (AttentionDestination) -> Void) {
        self.intent = intent
        self.context = context
        self.container = container
        self.onClose = onClose
        self.onCreated = onCreated
        _eventsStore = State(initialValue: EventsStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
        _moneyStore = State(initialValue: MoneyStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
        _resourcesStore = State(initialValue: ResourcesStore(rpc: container.rpc))
    }

    var body: some View {
        switch intent {
        case .event:
            // Trae su propio NavigationStack interno.
            CreateEventView(context: context, store: eventsStore, container: container, onCreated: { eventId in
                onCreated(.event(eventId: eventId, contextActorId: context.id, contextDisplayName: context.displayName))
            })
        case .expense:
            // Trae su propio NavigationStack interno.
            RecordExpenseView(context: context, store: moneyStore, container: container)
        case .decision:
            // CreateDecisionView NO trae NavigationStack — lo envolvemos aquí
            // para que el sheet tenga título + Cancel.
            NavigationStack {
                CreateDecisionView(context: context, container: container, onCreated: { decisionId in
                    onCreated(.decision(decisionId: decisionId, contextActorId: context.id))
                })
                    .navigationTitle("Nueva decisión")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            DismissButton()
                        }
                    }
            }
        case .document:
            NavigationStack {
                DocumentIntentLanding(context: context, container: container, onClose: onClose)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            DismissButton()
                        }
                    }
            }
        case .resource:
            // Subtype Picker UX D — wizard 3 pasos (class → subtype → form),
            // founder-firmado 2026-06-07. Reemplaza el legacy CreateResourceView.
            CreateResourceFlow(context: context, store: resourcesStore, container: container, onCreated: { resourceId in
                onCreated(.resourceDetail(resourceId: resourceId, contextActorId: context.id))
            })
        case .reservation:
            NavigationStack {
                ReservationIntentLanding(context: context, container: container, onClose: onClose)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            DismissButton()
                        }
                    }
            }
        case .obligation:
            // CreateObligationView trae su propio NavigationStack interno.
            CreateObligationView(context: context, container: container, onCreated: { obligationId in
                onCreated(.obligation(obligationId: obligationId, contextActorId: context.id))
            })
        }
    }
}

/// Helper para incluir un botón Cancelar que dismissea el sheet anidado.
private struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button("Cancelar") { dismiss() }
    }
}

/// F.NAV.8 — Resource picker para el intent "Subir documento". Lista los
/// recursos del contexto seleccionado. Tap → push a AttachDocumentView.
private struct DocumentIntentLanding: View {
    let context: AppContext
    let container: DependencyContainer
    let onClose: () -> Void

    @State private var resources: [ContextResource] = []
    @State private var phase: StorePhase = .idle
    @State private var documentsStore: DocumentsStore
    @State private var pickedResource: Resource?
    /// R.5Z.fix.10.b — flag para abrir AttachDocumentView con resource=nil.
    @State private var isShowingContextAttach = false

    init(context: AppContext, container: DependencyContainer, onClose: @escaping () -> Void) {
        self.context = context
        self.container = container
        self.onClose = onClose
        _documentsStore = State(initialValue: DocumentsStore(rpc: container.rpc))
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                List {
                    // R.5Z.fix.10.b — opción "Sin recurso" siempre arriba.
                    // Caso uso: estatutos, contratos macro, comprobantes admin.
                    Section {
                        Button {
                            isShowingContextAttach = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sin recurso").font(.callout.weight(.medium))
                                    Text("Documento del espacio").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if !resources.isEmpty {
                        Section {
                            ForEach(resources) { r in
                                Button {
                                    pickedResource = Resource(
                                        id: r.resourceId,
                                        resourceType: r.resourceType,
                                        displayName: r.displayName,
                                        status: r.status,
                                        estimatedValue: r.estimatedValue,
                                        currency: r.currency,
                                        canonicalOwnerActorId: r.canonicalOwnerActorId
                                    )
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
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Adjuntar a recurso")
                        }
                    }
                }
            }
        }
        .navigationTitle("Subir documento")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $pickedResource) { resource in
            AttachDocumentView(
                resource: resource,
                context: context,
                container: container,
                store: documentsStore
            )
        }
        .sheet(isPresented: $isShowingContextAttach) {
            AttachDocumentView(
                resource: nil,
                context: context,
                container: container,
                store: documentsStore
            )
        }
    }

    private func load() async {
        if resources.isEmpty { phase = .loading }
        do {
            resources = try await container.rpc.listContextResources(contextId: context.id)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}

/// Resource picker para el intent "Hacer reservación". Lista los recursos
/// reservables del contexto seleccionado. Tap → sheet con `RequestReservationView`.
private struct ReservationIntentLanding: View {
    let context: AppContext
    let container: DependencyContainer
    let onClose: () -> Void

    @State private var resources: [ContextResource] = []
    @State private var phase: StorePhase = .idle
    @State private var reservationsStore: ReservationsStore
    @State private var pickedResource: Resource?

    init(context: AppContext, container: DependencyContainer, onClose: @escaping () -> Void) {
        self.context = context
        self.container = container
        self.onClose = onClose
        _reservationsStore = State(initialValue: ReservationsStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
    }

    /// Recursos reservables — el backend marca tipos como `house`, `vehicle`,
    /// `equipment`, `property` como reservables vía capabilities. Filtramos
    /// client-side por tipo conocido como reservable; el backend rechazará si
    /// no aplica.
    private var reservableResources: [ContextResource] {
        let reservableTypes: Set<String> = [
            "house", "property", "vehicle", "equipment", "reservation", "trip_booking"
        ]
        return resources.filter { reservableTypes.contains($0.resourceType) }
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                if reservableResources.isEmpty {
                    ContentUnavailableView(
                        "Sin recursos reservables",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("\(context.displayName) no tiene casas, vehículos, equipos u otros activos reservables.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(reservableResources) { r in
                                Button {
                                    let resource = Resource(
                                        id: r.resourceId,
                                        resourceType: r.resourceType,
                                        displayName: r.displayName,
                                        status: r.status,
                                        estimatedValue: r.estimatedValue,
                                        currency: r.currency,
                                        canonicalOwnerActorId: r.canonicalOwnerActorId
                                    )
                                    Task {
                                        await reservationsStore.load(resourceId: r.resourceId, context: context)
                                        pickedResource = resource
                                    }
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
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Reservar en \(context.displayName)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Hacer reservación")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .sheet(item: $pickedResource) { resource in
            RequestReservationView(
                resource: resource,
                context: context,
                store: reservationsStore,
                container: container
            )
        }
    }

    private func load() async {
        if resources.isEmpty { phase = .loading }
        do {
            resources = try await container.rpc.listContextResources(contextId: context.id)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}

#Preview("CreateIntentSheet (demo)") {
    Color.clear.sheet(isPresented: .constant(true)) {
        CreateIntentSheet(container: .demo())
    }
}
