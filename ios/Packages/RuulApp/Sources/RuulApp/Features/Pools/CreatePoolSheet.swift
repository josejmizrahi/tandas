import SwiftUI
import RuulCore

/// R.8.E — crear un bote: nombre + política + meta opcional. El backend
/// valida (`create_pool`).
public struct CreatePoolSheet: View {
    let context: AppContext
    let store: PoolsStore
    /// R.16.B — metadata jsonb opcional que se pasa tal cual a `create_pool`.
    /// EventDetailTripSection manda `{"source_event_id": "<uuid>"}` para ligar
    /// el bote con el viaje. nil para los call sites existentes.
    let metadata: JSONValue?
    /// Callback opcional con el `poolAccountId` recién creado. El parent
    /// (CreateIntentSheet) lo usa para auto-pushear a PoolDetailView vía
    /// `AttentionDestination.poolDetail`. MoneyHomeView ignora este callback
    /// (basta con dismiss + refresh de la lista).
    var onCreated: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var policyKey = "winner_takes_all"
    @State private var targetAmountText = ""
    @State private var currency = "MXN"
    @State private var runner = ActionRunner()

    public init(
        context: AppContext,
        store: PoolsStore,
        initialName: String = "",
        metadata: JSONValue? = nil,
        onCreated: ((UUID) -> Void)? = nil
    ) {
        self.context = context
        self.store = store
        self.metadata = metadata
        self.onCreated = onCreated
        _name = State(initialValue: initialName)
    }

    private var targetAmount: Double? {
        Double(targetAmountText.replacingOccurrences(of: ",", with: ""))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Bote de la cena, JV Nave…", text: $name)
                }

                Section {
                    policyRow(
                        key: "winner_takes_all",
                        label: "Bote",
                        description: "Todo lo aportado se paga a una persona ganadora al resolver."
                    )
                    policyRow(
                        key: "equity_target",
                        label: "Bote con meta",
                        description: "Cada quien aporta hasta llegar a una meta. Al resolver quedan fijadas las participaciones."
                    )
                    policyRow(
                        key: "proportional",
                        label: "Proporcional",
                        description: "Al resolver, cada participante queda con su parte proporcional a lo aportado."
                    )
                } header: {
                    Text("¿Cómo se reparte?")
                }

                // Meta solo aplica al bote "Con meta" (equity_target). Para
                // bote y proporcional el monto target no tiene efecto backend.
                if policyKey == "equity_target" {
                    Section {
                        HStack {
                            Text("$")
                            TextField("Monto meta", text: $targetAmountText)
                                .keyboardType(.decimalPad)
                            TextField("MXN", text: $currency)
                                .textInputAutocapitalization(.characters)
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("Meta")
                    } footer: {
                        Text("Hasta cuánto se aporta. El bote deja de aceptar aportes al llegar a la meta.")
                    }
                } else {
                    Section("Moneda") {
                        TextField("MXN", text: $currency)
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
                            Text("Crear bote").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                }
            }
            .navigationTitle("Crear bote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    /// Fila rica con descripción inline. Reemplaza el Picker(.segmented) que
    /// solo mostraba labels técnicos sin contexto al momento de elegir.
    @ViewBuilder
    private func policyRow(key: String, label: String, description: String) -> some View {
        Button {
            policyKey = key
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: policyKey == key ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(policyKey == key ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.callout.weight(policyKey == key ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if policyKey == "equity_target" {
            // El backend exige meta positiva para equity_target.
            return (targetAmount ?? 0) > 0
        }
        return true
    }

    private func create() async {
        var createdPoolId: UUID?
        let success = await runner.run {
            let result = try await store.createPool(
                CreatePoolInput(
                    contextId: context.id,
                    displayName: name.trimmingCharacters(in: .whitespaces),
                    policyKey: policyKey,
                    currency: currency,
                    targetAmount: targetAmount,
                    metadata: metadata,
                    clientId: UUID().uuidString
                ),
                context: context
            )
            createdPoolId = result.poolAccountId
        }
        if success {
            if let id = createdPoolId { onCreated?(id) }
            dismiss()
        }
    }
}

#Preview("Crear bote") {
    CreatePoolSheet(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: PoolsStore(rpc: MockRuulRPCClient.demo())
    )
}
