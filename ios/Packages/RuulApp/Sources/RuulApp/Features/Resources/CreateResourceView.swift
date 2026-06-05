import SwiftUI
import RuulCore
import MapKit

/// F.6 / R.2M — crear un recurso gobernado por el contexto. El catálogo
/// de tipos se carga desde `resource_type_catalog()` (R.2M): labels, iconos
/// y capabilities vienen del backend. Fallback al enum `ResourceType` si el
/// catálogo aún no cargó (warm-up).
public struct CreateResourceView: View {
    let context: AppContext
    let store: ResourcesStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var description = ""
    @State private var selectedTypeKey: String = ResourceType.house.rawValue
    @State private var hasValue = false
    @State private var estimatedValue = ""
    @State private var currency = "MXN"
    @State private var runner = ActionRunner()
    /// F.RESOURCE.4 — ubicación opcional con autocomplete de Apple Maps.
    @State private var locationText = ""
    @State private var locationCompleter = LocationCompleter()
    @State private var suppressNextQueryUpdate = false
    /// R.2V.4 — creation guard: candidatos similares al nombre dentro del contexto.
    @State private var guardCandidates: [ResourceCreationCandidate] = []

    public init(context: AppContext, store: ResourcesStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    private var catalogStore: ResourceTypeCatalogStore { container.resourceTypeCatalogStore }

    /// Entries efectivas: catálogo backend si está cargado, fallback al enum.
    private var availableTypes: [ResourceTypeCatalogEntry] {
        let backendEntries = catalogStore.entries()
        if !backendEntries.isEmpty { return backendEntries }
        // Fallback warm-up: usamos el enum local (mismo shape).
        return ResourceType.allCases.map {
            ResourceTypeCatalogEntry(
                typeKey: $0.rawValue,
                displayName: $0.label,
                icon: $0.symbolName
            )
        }
    }

    private var selectedEntry: ResourceTypeCatalogEntry? {
        availableTypes.first { $0.typeKey == selectedTypeKey }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Recurso") {
                    TextField("Nombre (Casa Valle, Fondo común…)", text: $displayName)
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                CreationGuardView(
                    candidates: guardCandidates.map(CreationGuardCandidate.from)
                ) { _ in
                    // El recurso ya existe en este contexto; cierra el sheet
                    // y deja al usuario abrirlo desde la lista para evitar duplicado.
                    dismiss()
                }

                Section("Tipo") {
                    Picker("Tipo", selection: $selectedTypeKey) {
                        ForEach(availableTypes) { entry in
                            Label(entry.displayName, systemImage: entry.icon ?? "circle")
                                .tag(entry.typeKey)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if let entry = selectedEntry, !entry.capabilities.isEmpty {
                        // R.2M: mostramos las capabilities como insight para el
                        // usuario sobre lo que el tipo habilita.
                        Text(entry.capabilities.map { capabilityLabel($0) }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Dirección o lugar", text: $locationText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onChange(of: locationText) { _, new in
                            if suppressNextQueryUpdate {
                                suppressNextQueryUpdate = false
                                return
                            }
                            locationCompleter.setQuery(new)
                        }
                    ForEach(locationCompleter.suggestions) { suggestion in
                        Button {
                            pickLocation(suggestion)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.tint)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Ubicación")
                } footer: {
                    Text("Opcional. Casas, vehículos y juegos físicos pueden tener una; cuentas y activos digitales no.")
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
            .navigationTitle("Nuevo recurso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .task {
                await catalogStore.loadIfNeeded()
            }
            // R.2V.4 — debounce creation guard al teclear el nombre.
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
        .ruulSheet()
    }

    /// Capability legible (sin hardcodear comportamiento — solo presentación).
    private func capabilityLabel(_ key: String) -> String {
        switch key {
        case "reservable": return "Reservable"
        case "monetary": return "Monetario"
        case "transferable": return "Transferible"
        case "shareable": return "Compartible"
        case "governable": return "Gobernable"
        case "beneficiary_supported": return "Beneficiarios"
        case "approval_required": return "Requiere aprobación"
        case "expirable": return "Expira"
        case "depreciable": return "Se deprecia"
        case "documentable": return "Documentos"
        case "sellable": return "Vendible"
        case "rentable": return "Rentable"
        case "auditable": return "Auditable"
        case "ownership_trackable": return "Propiedad rastreable"
        case "maintainable": return "Mantenimiento"
        default: return key
        }
    }

    private func create() async {
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        let success = await runner.run {
            _ = try await store.createResource(
                CreateResourceInput(
                    contextId: context.id,
                    resourceTypeKey: selectedTypeKey,
                    displayName: displayName.trimmingCharacters(in: .whitespaces),
                    description: description.isEmpty ? nil : description,
                    estimatedValue: hasValue ? Double(estimatedValue) : nil,
                    currency: hasValue ? currency : nil,
                    locationText: trimmedLocation.isEmpty ? nil : trimmedLocation,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
    }

    private func pickLocation(_ suggestion: LocationSuggestion) {
        let composed = suggestion.subtitle.isEmpty
            ? suggestion.title
            : "\(suggestion.title), \(suggestion.subtitle)"
        suppressNextQueryUpdate = true
        locationText = composed
        locationCompleter.clear()
    }
}

#Preview("Crear recurso") {
    CreateResourceView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi"
        ),
        store: ResourcesStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
