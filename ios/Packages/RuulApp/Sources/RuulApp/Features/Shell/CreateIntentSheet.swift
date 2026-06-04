import SwiftUI
import RuulCore

/// F.NAV.5 — Sheet intent-first "¿Qué quieres hacer?". El tab Crear no tiene
/// pantalla propia: tap → sheet → pick intent → pick contexto (si aplica) →
/// abrir el flow correspondiente.
///
/// Doctrina: el botón Crear NO expone primitivas. El usuario eligió una
/// intención (Programar algo / Registrar movimiento / Crear propuesta /
/// Subir documento / Crear contexto). El backend ya tiene los flows; iOS
/// sólo conecta intención → form.
public struct CreateIntentSheet: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    /// F.NAV.7+: el form (CreateEventView / RecordExpenseView / etc.) trae
    /// SU PROPIO NavigationStack interno. Anidarlo dentro del NavigationStack
    /// de la sheet crashea SwiftUI iOS 16+. Por eso presentamos el form como
    /// sheet anidado sobre la sheet de intent, no como push.
    @State private var pendingForm: PendingForm?

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    intentRow(.event,     icon: "calendar.badge.plus",     tint: .orange, label: "Programar algo",
                              detail: "Crear un evento del contexto.")
                    intentRow(.expense,   icon: "dollarsign.circle.fill",  tint: .green,  label: "Registrar movimiento",
                              detail: "Anotar un gasto o ingreso.")
                    intentRow(.decision,  icon: "checkmark.bubble.fill",   tint: .purple, label: "Crear propuesta",
                              detail: "Abrir una decisión para votar.")
                    intentRow(.document,  icon: "paperclip",               tint: .secondary, label: "Subir documento",
                              detail: "Adjuntar un archivo a un recurso.")
                } header: {
                    Text("¿Qué quieres hacer?")
                        .font(.subheadline.weight(.semibold))
                }

                Section {
                    Button {
                        path.append(.createContext)
                    } label: {
                        intentLabel(icon: "rectangle.split.2x1.fill", tint: .blue,
                                    label: "Crear contexto",
                                    detail: "Una familia, viaje, proyecto, comunidad…")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Espacio nuevo")
                }
            }
            .navigationTitle("Crear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                routeDestination(route)
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
                }
            )
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func intentRow(_ intent: Intent, icon: String, tint: Color, label: String, detail: String) -> some View {
        Button {
            path.append(.pickContext(intent: intent))
        } label: {
            intentLabel(icon: icon, tint: tint, label: label, detail: detail)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func intentLabel(icon: String, tint: Color, label: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: Circle())
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

    // MARK: - Navigation

    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        switch route {
        case .pickContext(let intent):
            ContextPickerView(container: container, intent: intent) { ctx in
                // F.NAV.7+: en lugar de push (que causaba NavigationStack
                // anidado), guardamos el form en pendingForm para abrir como
                // sheet anidada sobre la sheet actual.
                pendingForm = PendingForm(intent: intent, context: ctx)
            }
        case .createContext:
            // CreateContextView trae su propia UI/navegación.
            CreateContextView(container: container)
        }
    }

    // MARK: - Tipos

    enum Intent: Hashable {
        case event, expense, decision, document
    }

    enum Route: Hashable {
        case pickContext(intent: Intent)
        case createContext
    }

    /// Sheet anidada pendiente. `Identifiable` para `.sheet(item:)`.
    struct PendingForm: Identifiable {
        let id = UUID()
        let intent: Intent
        let context: AppContext
    }
}

// MARK: - Context picker

private struct ContextPickerView: View {
    let container: DependencyContainer
    let intent: CreateIntentSheet.Intent
    let onPick: (AppContext) -> Void

    /// F.NAV.7 fix: pre-resolver arrays con identidades estables — los ForEach
    /// con `if let` condicional adentro causaban crashes esporádicos por
    /// inestabilidad de identidad en SwiftUI.
    private var allCollectives: [AppContext] {
        container.contextStore.availableContexts.filter { !$0.isPersonal }
    }

    private var recentCollectives: [AppContext] {
        let lookup = Dictionary(uniqueKeysWithValues: allCollectives.map { ($0.id, $0) })
        return container.contextPreferencesStore.recents.compactMap { lookup[$0.contextActorId] }
    }

    private var otherCollectives: [AppContext] {
        let recentIds = Set(recentCollectives.map(\.id))
        return allCollectives.filter { !recentIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if allCollectives.isEmpty {
                ContentUnavailableView(
                    "Sin contextos",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Crea un contexto primero desde \"Crear contexto\".")
                )
            } else {
                List {
                    if !recentCollectives.isEmpty {
                        Section("Recientes") {
                            ForEach(recentCollectives) { ctx in row(ctx) }
                        }
                    }
                    if !otherCollectives.isEmpty {
                        Section(recentCollectives.isEmpty ? "Tus contextos" : "Todos") {
                            ForEach(otherCollectives) { ctx in row(ctx) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Elige el contexto")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ ctx: AppContext) -> some View {
        Button {
            onPick(ctx)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ctx.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.displayName).font(.callout.weight(.medium))
                    Text("\(ctx.memberCount) miembros").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
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

    @State private var eventsStore: EventsStore
    @State private var moneyStore: MoneyStore

    init(intent: CreateIntentSheet.Intent, context: AppContext, container: DependencyContainer, onClose: @escaping () -> Void) {
        self.intent = intent
        self.context = context
        self.container = container
        self.onClose = onClose
        _eventsStore = State(initialValue: EventsStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
        _moneyStore = State(initialValue: MoneyStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        ))
    }

    var body: some View {
        switch intent {
        case .event:
            // Trae su propio NavigationStack interno.
            CreateEventView(context: context, store: eventsStore, container: container)
        case .expense:
            // Trae su propio NavigationStack interno.
            RecordExpenseView(context: context, store: moneyStore, container: container)
        case .decision:
            // CreateDecisionView NO trae NavigationStack — lo envolvemos aquí
            // para que el sheet tenga título + Cancel.
            NavigationStack {
                CreateDecisionView(context: context, container: container)
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
                LoadingStateView()
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await load() }
                }
            case .loaded:
                if resources.isEmpty {
                    ContentUnavailableView(
                        "Sin recursos",
                        systemImage: "shippingbox",
                        description: Text("\(context.displayName) no tiene recursos aún. Crea uno primero.")
                    )
                } else {
                    List {
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
                            Text("Adjuntar a recurso en \(context.displayName)")
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
