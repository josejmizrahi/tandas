import SwiftUI
import RuulCore
import RuulUI

/// Contribution sheet — invoked from the fund detail view's primary CTA
/// ("Aportar"). Records a positive contribution into the fund's ledger
/// via `fundRepo.contribute` → `fund_contribute` RPC (mig 00202).
///
/// Surface:
///   - Amount in pesos (typed in the fund's currency)
///   - Optional note ("aporte de marzo", "te debía esto", ...)
///
/// Submit path:
///   `FundRepository.contribute(fundId, amountCents, currency, note)` →
///   `fund_contribute` RPC →
///   `record_ledger_entry` (type='contribution', from=caller, to=NULL,
///   resource_id=fund) →
///   `fund_balance_view` reflects the new balance on next read.
///
/// On success the parent reloads its balance snapshot via `onDidContribute`.
public struct ContributeToFundSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let fundId: UUID
    public let fundName: String
    public let currency: String
    /// Called after a successful contribute so the caller can refresh
    /// the balance card.
    public let onDidContribute: () -> Void

    @State private var amountText: String = ""
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        fundId: UUID,
        fundName: String,
        currency: String,
        onDidContribute: @escaping () -> Void
    ) {
        self.fundId = fundId
        self.fundName = fundName
        self.currency = currency
        self.onDidContribute = onDidContribute
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fundName)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                } footer: {
                    Text("Tu aportación entra al fondo y suma al balance común.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }

                Section("Monto (\(currency))") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Nota (opcional)") {
                    TextField("ej: Aporte de marzo", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
            }
            .navigationTitle("Aportar al fondo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Aportando…" : "Aportar") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || amountCents == nil)
                }
            }
        }
    }

    /// Parses `amountText` (pesos with optional cents) into cents.
    /// Returns nil for empty / unparseable / non-positive inputs so the
    /// confirm button stays disabled and `submit()` never proceeds.
    private var amountCents: Int64? {
        let trimmed = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let pesos = Double(trimmed), pesos > 0 else {
            return nil
        }
        // Round half-up — typing $1.005 should land as 101 cents, not 100.
        return Int64((pesos * 100).rounded())
    }

    @MainActor
    private func submit() async {
        guard let cents = amountCents else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await app.fundRepo.contribute(
                fundId: fundId,
                amountCents: cents,
                currency: currency,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            onDidContribute()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
