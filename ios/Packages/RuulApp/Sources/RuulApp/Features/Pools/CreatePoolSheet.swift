import SwiftUI
import RuulCore

/// R.8.E — crear un fondo: nombre + política (solo las 2 MVP: Bote /
/// Fondo con meta) + meta opcional. El backend valida (`create_pool`).
public struct CreatePoolSheet: View {
    let context: AppContext
    let store: PoolsStore

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var policyKey = "winner_takes_all"
    @State private var targetAmountText = ""
    @State private var currency = "MXN"
    @State private var runner = ActionRunner()

    public init(context: AppContext, store: PoolsStore) {
        self.context = context
        self.store = store
    }

    private var targetAmount: Double? {
        Double(targetAmountText.replacingOccurrences(of: ",", with: ""))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Fondo") {
                    TextField("Nombre (Bote de la cena, JV Nave…)", text: $name)
                    Picker("Tipo", selection: $policyKey) {
                        Text("Bote").tag("winner_takes_all")
                        Text("Con meta").tag("equity_target")
                        Text("Proporcional").tag("proportional")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Meta") {
                    HStack {
                        Text("$")
                        TextField(policyKey == "equity_target" ? "Monto meta" : "Opcional", text: $targetAmountText)
                            .keyboardType(.decimalPad)
                        TextField("MXN", text: $currency)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear fondo").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValid || runner.isRunning)
                } footer: {
                    if policyKey == "proportional" {
                        Text("Al resolver, cada participante queda con su parte proporcional a lo aportado.")
                    } else if policyKey == "winner_takes_all" {
                        Text("Bote: todo lo aportado se paga a una persona ganadora al resolver.")
                    } else {
                        Text("Fondo con meta: cada quien aporta y al resolver quedan fijadas las participaciones.")
                    }
                }
            }
            .navigationTitle("Crear fondo")
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

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if policyKey == "equity_target" {
            // El backend exige meta positiva para equity_target.
            return (targetAmount ?? 0) > 0
        }
        return true
    }

    private func create() async {
        let success = await runner.run {
            _ = try await store.createPool(
                CreatePoolInput(
                    contextId: context.id,
                    displayName: name.trimmingCharacters(in: .whitespaces),
                    policyKey: policyKey,
                    currency: currency,
                    targetAmount: targetAmount,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
    }
}

#Preview("Crear fondo") {
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
