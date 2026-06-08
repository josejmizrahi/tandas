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

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando categorías…")
            case .failed(let message):
                RuulErrorState(message: message) { Task { await load() } }
            case .loaded:
                List(classes) { cls in
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
    @State private var displayName = ""
    @State private var descriptionText = ""
    @State private var hasValue = false
    @State private var estimatedValue = ""
    @State private var currency = "MXN"
    @State private var locationText = ""
    @State private var runner = ActionRunner()
    @State private var guardCandidates: [ResourceCreationCandidate] = []

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
