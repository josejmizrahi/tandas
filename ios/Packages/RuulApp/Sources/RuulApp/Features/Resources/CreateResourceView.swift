import SwiftUI
import RuulCore

/// F.6 — crear un recurso gobernado por el contexto.
public struct CreateResourceView: View {
    let context: AppContext
    let store: ResourcesStore

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var description = ""
    @State private var resourceType: ResourceType = .house
    @State private var hasValue = false
    @State private var estimatedValue = ""
    @State private var currency = "MXN"
    @State private var runner = ActionRunner()

    public init(context: AppContext, store: ResourcesStore) {
        self.context = context
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Recurso") {
                    TextField("Nombre (Casa Valle, Fondo común…)", text: $displayName)
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Tipo") {
                    Picker("Tipo", selection: $resourceType) {
                        ForEach(ResourceType.allCases) { type in
                            Label(type.label, systemImage: type.symbolName).tag(type)
                        }
                    }
                    .pickerStyle(.navigationLink)
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
            .actionErrorAlert(runner)
        }
    }

    private func create() async {
        let success = await runner.run {
            _ = try await store.createResource(
                CreateResourceInput(
                    contextId: context.id,
                    resourceType: resourceType,
                    displayName: displayName.trimmingCharacters(in: .whitespaces),
                    description: description.isEmpty ? nil : description,
                    estimatedValue: hasValue ? Double(estimatedValue) : nil,
                    currency: hasValue ? currency : nil,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
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
        store: ResourcesStore(rpc: MockRuulRPCClient.demo())
    )
}
