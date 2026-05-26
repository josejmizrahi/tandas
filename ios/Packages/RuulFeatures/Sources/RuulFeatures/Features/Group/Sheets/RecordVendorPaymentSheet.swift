import SwiftUI
import RuulCore
import RuulUI

/// Phase 4.5 (2026-05-26): "Pagar a un proveedor externo" — el pool
/// gasta dinero directo, sin miembro fronter ni receivable. Casos:
///   * Construcción de una nave (sociedad): pagar al maestro de obra,
///     al ferretero, al permiso municipal.
///   * Viaje compartido: pagar el hotel desde el bote.
///   * Cualquier gasto donde el dinero YA está en el pool y sale al
///     mundo externo.
///
/// Distinto de `RecordSharedExpenseSheet`:
///   * `RecordSharedExpenseSheet` → un miembro fronteó, el pool le
///     debe / le reembolsa. Crea receivable o split obligations.
///   * `RecordVendorPaymentSheet` → no hay miembro contraparte. Solo
///     baja el balance del pool y queda el comprobante del proveedor.
///
/// Backend RPC: `record_pool_payment_to_vendor` (mig 20260526050000).
/// Idempotente vía stable clientId.
@MainActor
public struct RecordVendorPaymentSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    /// Optional resource attribution (la nave que se está construyendo,
    /// el viaje, etc). Cuando llega pre-filled, el campo se bloquea —
    /// el contexto vino del recurso de origen.
    public let sourceResource: (id: UUID, name: String)?
    public let onDidRecord: () -> Void

    @State private var amountText: String = ""
    @State private var vendorName: String = ""
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var clientId: UUID = UUID()
    @State private var successPhrase: String?

    public init(
        groupId: UUID,
        currency: String,
        sourceResource: (id: UUID, name: String)? = nil,
        onDidRecord: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.sourceResource = sourceResource
        self.onDidRecord = onDidRecord
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sourceResource {
                        Label("Para \(sourceResource.name)", systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } footer: {
                    Text("El pool paga directo al proveedor. NO crea reembolso a un miembro — el dinero ya estaba en el pool y sale al exterior.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    HStack {
                        Text("$")
                            .foregroundStyle(Color.secondary)
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                        Text(currency)
                            .foregroundStyle(Color.secondary)
                    }
                } header: {
                    Text("Monto")
                }

                Section("Proveedor") {
                    TextField("ej: Maestro Pedro, Home Depot, Hotel X", text: $vendorName)
                        .textInputAutocapitalization(.words)
                }

                Section("Nota (opcional)") {
                    TextField("ej: factura #1234, cemento + varilla", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }

                if let phrase = successPhrase {
                    Section {
                        Label(phrase, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ruulPositive)
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: successPhrase)
            .ruulSheetToolbar("Pagar a proveedor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonLabel) {
                        RuulHaptic.light.trigger()
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting || successPhrase != nil)
                }
            }
            .sensoryFeedback(.success, trigger: successPhrase)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
    }

    private var canSubmit: Bool {
        guard let cents = parsedCents, cents > 0 else { return false }
        return true
    }

    private var parsedCents: Int64? {
        let normalized = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let pesos = Double(normalized), pesos > 0 else {
            return nil
        }
        return Int64((pesos * 100).rounded())
    }

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Registrando…" }
        return "Pagar"
    }

    @MainActor
    private func submit() async {
        guard let cents = parsedCents else { return }
        isSubmitting = true
        errorMessage = nil
        let trimmedVendor = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await app.ledgerRepo.recordPoolPaymentToVendor(
                groupId: groupId,
                amountCents: cents,
                currency: currency,
                vendorName: trimmedVendor.isEmpty ? nil : trimmedVendor,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                sourceResourceId: sourceResource?.id,
                clientId: clientId
            )
            isSubmitting = false
            successPhrase = composeSuccess(cents: cents)
            try? await Task.sleep(for: .milliseconds(700))
            onDidRecord()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            RuulHaptic.error.trigger()
        }
    }

    private func composeSuccess(cents: Int64) -> String {
        let amount = formattedCents(cents)
        let trimmedVendor = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVendor.isEmpty {
            return "El pool pagó \(amount) a \(trimmedVendor)"
        }
        return "El pool pagó \(amount)"
    }

    private func formattedCents(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "es_MX")
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
    }
}
