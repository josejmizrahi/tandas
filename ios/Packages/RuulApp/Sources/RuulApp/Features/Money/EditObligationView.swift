import SwiftUI
import RuulCore

/// F.MONEY.4 — editar título / descripción / fecha límite / monto / moneda
/// de una obligación activa. Acción canónica `edit_obligation` gateada por
/// acreedor o `money.settle` en backend. Para obligaciones kind ≠ money,
/// el monto/moneda no aparecen.
public struct EditObligationView: View {
    let detail: ObligationDetail
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var dueAt: Date
    @State private var hasDueAt: Bool
    @State private var amountText: String
    @State private var currency: String
    @State private var runner = ActionRunner()

    private let currencyOptions = ["MXN", "USD", "EUR"]

    public init(
        detail: ObligationDetail,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.detail = detail
        self.container = container
        self.onSaved = onSaved
        _title = State(initialValue: detail.title ?? "")
        _description = State(initialValue: detail.description ?? "")
        _dueAt = State(initialValue: detail.dueAt ?? Date().addingTimeInterval(7 * 24 * 3600))
        _hasDueAt = State(initialValue: detail.dueAt != nil)
        let amount = detail.amount ?? 0
        _amountText = State(initialValue: amount > 0 ? String(format: "%.2f", amount) : "")
        _currency = State(initialValue: detail.currency ?? "MXN")
    }

    private var isMoney: Bool { detail.kind == "money" }

    private var canSubmit: Bool {
        if runner.isRunning { return false }
        if isMoney {
            guard let parsed = parsedAmount, parsed > 0 else { return false }
            _ = parsed
        }
        return true
    }

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    public var body: some View {
        NavigationStack {
            Form {
                if isMoney {
                    Section("Monto") {
                        TextField("Cantidad", text: $amountText)
                            .keyboardType(.decimalPad)
                        Picker("Moneda", selection: $currency) {
                            ForEach(currencyOptions, id: \.self) { c in
                                Text(c).tag(c)
                            }
                        }
                    }
                }

                Section("Detalles") {
                    TextField("Título (opcional)", text: $title)
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Toggle("Definir fecha límite", isOn: $hasDueAt)
                    if hasDueAt {
                        DatePicker("Vence el", selection: $dueAt)
                    }
                } header: {
                    Text("Fecha límite")
                } footer: {
                    Text("Sirve para recordatorios. Puedes dejarla abierta si no hay fecha fija.")
                }
            }
            .navigationTitle("Editar obligación")
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
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let newDueAt = hasDueAt ? dueAt : nil
        let newAmount = isMoney ? parsedAmount : nil

        let input = UpdateObligationInput(
            obligationId: detail.id,
            title: trimmedTitle == (detail.title ?? "") ? nil : trimmedTitle,
            description: trimmedDescription == (detail.description ?? "") ? nil : trimmedDescription,
            dueAt: newDueAt == detail.dueAt ? nil : newDueAt,
            amount: newAmount == detail.amount ? nil : newAmount,
            currency: (isMoney && currency != (detail.currency ?? "MXN")) ? currency : nil
        )
        let success = await runner.run {
            _ = try await container.rpc.updateObligation(input)
        }
        if success {
            onSaved()
            dismiss()
        }
    }
}
