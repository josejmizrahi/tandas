import SwiftUI
import RuulCore
import RuulUI

/// Expense sheet — invoked from the fund detail view's secondary menu
/// ("Registrar gasto"). Records a payout from the fund to a recipient
/// member via `fundRepo.recordExpense` → `fund_record_expense` RPC
/// (mig 00202).
///
/// Surface:
///   - Recipient member picker (required — vendor expenses with no
///     recipient are out of scope per the RPC's direction-based math)
///   - Amount in pesos (typed in the fund's currency)
///   - Optional note ("compra de bocadillos", "reembolso a Maria")
///
/// Submit path:
///   `FundRepository.recordExpense(fundId, amountCents, toMemberId,
///   currency, note)` → `fund_record_expense` RPC →
///   `record_ledger_entry` (type='expense', from=NULL, to=toMemberId,
///   resource_id=fund) → `fund_balance_view` reflects the new balance.
public struct RecordExpenseFromFundSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let fundId: UUID
    public let fundName: String
    public let currency: String
    public let members: [MemberWithProfile]
    /// Called after a successful expense record so the caller can refresh
    /// the balance card.
    public let onDidRecord: () -> Void

    @State private var toMemberId: UUID?
    @State private var amountText: String = ""
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        fundId: UUID,
        fundName: String,
        currency: String,
        members: [MemberWithProfile],
        onDidRecord: @escaping () -> Void
    ) {
        self.fundId = fundId
        self.fundName = fundName
        self.currency = currency
        self.members = members
        self.onDidRecord = onDidRecord
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fundName)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                } footer: {
                    Text("El gasto sale del fondo y se acredita al destinatario. Para registrar un gasto a un proveedor externo, usa el ledger general.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }

                Section("Destinatario") {
                    Picker("", selection: $toMemberId) {
                        Text("Elige…").tag(Optional<UUID>.none)
                        ForEach(members) { m in
                            Text(m.displayName).tag(Optional(m.member.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Section("Monto (\(currency))") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Nota (opcional)") {
                    TextField("ej: Bocadillos para la junta", text: $note, axis: .vertical)
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
            .ruulSheetToolbar("Registrar gasto")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Registrando…" : "Registrar") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || toMemberId == nil || amountCents == nil)
                }
            }
        }
    }

    private var amountCents: Int64? {
        let trimmed = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let pesos = Double(trimmed), pesos > 0 else {
            return nil
        }
        return Int64((pesos * 100).rounded())
    }

    @MainActor
    private func submit() async {
        guard let cents = amountCents, let toId = toMemberId else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await app.fundRepo.recordExpense(
                fundId: fundId,
                amountCents: cents,
                toMemberId: toId,
                currency: currency,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            onDidRecord()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
