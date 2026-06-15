import SwiftUI
import RuulCore
import MapKit

/// F.RESOURCE.3 — editar campos generales del recurso (nombre / descripción /
/// valor estimado / moneda / ubicación) sin pasar por Settings. Action
/// canónica `update_resource` gateada por OWN/MANAGE en backend.
///
/// R.12.E — si el caller pasa `subtypeKey`, se carga el `ResourceSubtype` con
/// sus fields y se muestra un section "Detalles <subtipo>" con DynamicForm
/// prefilled del `resource.metadata` actual.
public struct EditResourceView: View {
    let resource: Resource
    let subtypeKey: String?
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var description: String
    @State private var estimatedValue: String
    @State private var currency: String
    @State private var locationText: String
    @State private var locationCompleter = LocationCompleter()
    @State private var suppressNextQueryUpdate = false
    @State private var runner = ActionRunner()
    /// R.12.E — schema + values del subtype (carga async via listResourceSubtypes).
    @State private var subtypeFields: [FormFieldSpec] = []
    @State private var subtypeDisplayName: String = ""
    @State private var subtypeMetadata: [String: JSONValue] = [:]
    @State private var initialSubtypeMetadata: [String: JSONValue] = [:]

    private let currencyOptions = ["MXN", "USD", "EUR"]

    public init(
        resource: Resource,
        subtypeKey: String? = nil,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.resource = resource
        self.subtypeKey = subtypeKey
        self.container = container
        self.onSaved = onSaved
        _displayName = State(initialValue: resource.displayName)
        _description = State(initialValue: resource.description ?? "")
        let value = resource.estimatedValue ?? 0
        _estimatedValue = State(initialValue: value > 0 ? String(format: "%.2f", value) : "")
        _currency = State(initialValue: resource.currency ?? "MXN")
        _locationText = State(initialValue: resource.locationText ?? "")
        // Pre-cargar metadata existente del resource para que el form arranque
        // con los valores actuales. Si resource.metadata es .object lo usamos
        // directo; si no, dejamos vacío.
        if case .object(let obj) = resource.metadata {
            _subtypeMetadata = State(initialValue: obj)
            _initialSubtypeMetadata = State(initialValue: obj)
        }
    }

    /// 7.F.1 (audit 2026-06-14) — pattern universal de los Edit*View:
    /// `canSubmit = isValid && hasChanges && !runner.isRunning`. Evita PUT
    /// vacíos al backend cuando el usuario abre Editar y solo toca el
    /// teclado.
    private var canSubmit: Bool {
        isValid && hasChanges && !runner.isRunning
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasChanges: Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        let originalDescription = resource.description ?? ""
        let originalLocation = resource.locationText ?? ""
        let originalCurrency = resource.currency ?? "MXN"
        let parsedValue = Double(estimatedValue.replacingOccurrences(of: ",", with: "."))
        let originalValue = resource.estimatedValue

        return trimmedName != resource.displayName
            || trimmedDescription != originalDescription
            || trimmedLocation != originalLocation
            || currency != originalCurrency
            || parsedValue != originalValue
            || subtypeMetadata != initialSubtypeMetadata
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Recurso") {
                    TextField("Nombre", text: $displayName)
                        .textInputAutocapitalization(.words)
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
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
                    Text("Opcional. Borra el campo para limpiar la ubicación.")
                }

                Section {
                    TextField("Valor estimado", text: $estimatedValue)
                        .keyboardType(.decimalPad)
                    Picker("Moneda", selection: $currency) {
                        ForEach(currencyOptions, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                } header: {
                    Text("Valor")
                } footer: {
                    Text("Sirve para reportes y liquidaciones. Déjalo en blanco si no aplica.")
                }

                if !subtypeFields.isEmpty {
                    Section {
                        DynamicForm(
                            schema: FormSchema(fields: subtypeFields),
                            values: $subtypeMetadata
                        )
                    } header: {
                        Text("Detalles \(subtypeDisplayName.lowercased())")
                    }
                }
            }
            .task { await loadSubtypeFields() }
            .navigationTitle("Editar recurso")
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
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        let parsedValue = Double(estimatedValue.replacingOccurrences(of: ",", with: "."))
        // F.RESOURCE.4 — mismo patrón que EditEventView: mandamos valores del
        // form siempre; el backend usa coalesce + sentinela "" para limpiar
        // location_text.
        // R.12.E — metadata se envía solo si el form de subtype cambió, para
        // no sobrescribir campos preexistentes que iOS no conoce.
        let metadataPayload: JSONValue? = (subtypeMetadata != initialSubtypeMetadata)
            ? .object(subtypeMetadata)
            : nil
        let input = UpdateResourceInput(
            resourceId: resource.id,
            displayName: trimmedName,
            description: trimmedDescription,
            estimatedValue: parsedValue,
            currency: currency,
            metadata: metadataPayload,
            // "" explícito limpia el campo en backend; nil = no cambiar.
            locationText: trimmedLocation
        )
        let success = await runner.run {
            _ = try await container.rpc.updateResource(input)
        }
        if success {
            onSaved()
            dismiss()
        }
    }

    /// R.12.E — carga el subtype con sus FormFieldSpec[] desde el catalog. Si
    /// el caller no pasó `subtypeKey`, no aparece el section. Falla silencioso
    /// (subtypeFields queda vacío y la section no se renderea).
    private func loadSubtypeFields() async {
        guard let key = subtypeKey, !key.isEmpty else { return }
        guard subtypeFields.isEmpty else { return }
        do {
            let all = try await container.rpc.listResourceSubtypes(classKey: nil)
            if let match = all.first(where: { $0.subtypeKey == key }) {
                subtypeFields = match.fields
                subtypeDisplayName = match.displayName
            }
        } catch {
            // Sin schema disponible — section no aparece.
        }
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

#Preview("Editar recurso") {
    EditResourceView(
        resource: Resource(
            id: UUID(),
            resourceType: "house",
            displayName: "Casa Valle",
            description: "Casa familiar",
            estimatedValue: 2_500_000,
            currency: "MXN"
        ),
        container: .demo(),
        onSaved: {}
    )
}
