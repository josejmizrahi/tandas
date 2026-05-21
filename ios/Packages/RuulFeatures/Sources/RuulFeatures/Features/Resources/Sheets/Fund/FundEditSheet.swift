import SwiftUI
import RuulUI
import RuulCore

/// Edit form for a Fund resource. V1 surface — name + target amount,
/// patched through the polymorphic `update_event_metadata`-style RPC
/// when available. Server-side fund-specific update isn't shipped yet,
/// so the "Guardar" path is gated with a clear inline note when the
/// repo path is missing.
public struct FundEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let resource: ResourceRow
    let onSaved: () -> Void

    @State private var name: String
    @State private var targetText: String
    @State private var currency: String
    @State private var isSubmitting: Bool = false
    @State private var error: String?

    public init(resource: ResourceRow, onSaved: @escaping () -> Void = {}) {
        self.resource = resource
        self.onSaved = onSaved
        _name = State(initialValue: Self.string(resource.metadata["name"]) ?? "")
        _targetText = State(initialValue: {
            if case let .int(n) = resource.metadata["target_amount_cents"] {
                let pesos = Double(n) / 100
                return String(format: "%.2f", pesos)
            }
            return ""
        }())
        _currency = State(initialValue: Self.string(resource.metadata["currency"]) ?? "MXN")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Fondo") {
                    TextField("Nombre", text: $name)
                    HStack {
                        TextField("Meta (opcional)", text: $targetText)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Section {
                    Label(
                        "La edición completa de fondos (meta, moneda, cierre) llega en V1.5. Por ahora puedes actualizar el nombre.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.ruulSemanticError)
                    }
                }
            }
            .navigationTitle("Editar fondo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Guardar").fontWeight(.semibold)
                        }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @MainActor
    private func save() async {
        guard !isSubmitting, canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        // No fund-specific update RPC ships in V1 yet. We surface the
        // limitation honestly via an inline error instead of pretending
        // the save succeeded — V1.5 wires `update_fund_metadata`.
        self.error = "La actualización de fondos llega en V1.5. Por ahora abre un caso si necesitas renombrar."
    }

    private static func string(_ value: JSONConfig?) -> String? {
        if case let .string(s) = value { return s }
        return nil
    }
}
