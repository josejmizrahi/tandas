import SwiftUI
import RuulCore

/// F.RESOURCE.3 — editar campos generales del recurso (nombre / descripción /
/// valor estimado / moneda) sin pasar por Settings. Action canónica
/// `update_resource` gateada por OWN/MANAGE en backend.
public struct EditResourceView: View {
    let resource: Resource
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var description: String
    @State private var estimatedValue: String
    @State private var currency: String
    @State private var runner = ActionRunner()

    private let currencyOptions = ["MXN", "USD", "EUR"]

    public init(
        resource: Resource,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.resource = resource
        self.container = container
        self.onSaved = onSaved
        _displayName = State(initialValue: resource.displayName)
        _description = State(initialValue: resource.description ?? "")
        let value = resource.estimatedValue ?? 0
        _estimatedValue = State(initialValue: value > 0 ? String(format: "%.2f", value) : "")
        _currency = State(initialValue: resource.currency ?? "MXN")
    }

    private var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty && !runner.isRunning
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
            }
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
        let parsedValue = Double(estimatedValue.replacingOccurrences(of: ",", with: "."))
        // Sólo mandamos campos que cambiaron — NULL = "no cambiar" en backend.
        let input = UpdateResourceInput(
            resourceId: resource.id,
            displayName: trimmedName == resource.displayName ? nil : trimmedName,
            description: trimmedDescription == (resource.description ?? "") ? nil : trimmedDescription,
            estimatedValue: parsedValue == resource.estimatedValue ? nil : parsedValue,
            currency: currency == (resource.currency ?? "MXN") ? nil : currency
        )
        let success = await runner.run {
            _ = try await container.rpc.updateResource(input)
        }
        if success {
            onSaved()
            dismiss()
        }
    }
}

#Preview("Editar recurso") {
    EditResourceView(
        resource: Resource(
            id: UUID(),
            canonicalOwnerActorId: UUID(),
            displayName: "Casa Valle",
            resourceType: "house",
            description: "Casa familiar",
            estimatedValue: 2_500_000,
            currency: "MXN",
            status: "active"
        ),
        container: .demo(),
        onSaved: {}
    )
}
