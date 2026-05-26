import SwiftUI
import RuulCore
import RuulUI

/// Phase 4.4 (2026-05-26): pay a single pool charge (cuota / buy-in /
/// tanda contribution). Confirmation sheet — the debtor (or whoever
/// is covering for them) reviews the amount + reason and taps to
/// commit. Submission emits a `contribution` ledger entry and closes
/// the obligation atomically.
///
/// Backend RPC: `pay_pool_charge` (mig 20260526040000). Idempotente
/// via stable `clientId` generated on sheet open.
///
/// Tri-role payer: by default the debtor pays for themselves. A third
/// party (founder paying for a member, friend covering a buy-in) can
/// flip the picker — `paid_by_member_id` stamps into the ledger
/// metadata for audit.
@MainActor
public struct PayPoolChargeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let charge: Obligation
    public let members: [MemberWithProfile]
    public let onDidPay: () -> Void

    @State private var note: String = ""
    @State private var payerMemberId: UUID
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var clientId: UUID = UUID()
    @State private var successPhrase: String?

    public init(
        charge: Obligation,
        members: [MemberWithProfile],
        onDidPay: @escaping () -> Void
    ) {
        self.charge = charge
        self.members = members
        self.onDidPay = onDidPay
        self._payerMemberId = State(initialValue: charge.owedByMemberId)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(formattedCents(charge.amountCents))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    } label: {
                        Text("Cuota")
                            .foregroundStyle(Color.secondary)
                    }
                    if let reason = charge.reason, !reason.isEmpty {
                        LabeledContent {
                            Text(reason)
                                .foregroundStyle(Color.primary)
                        } label: {
                            Text("Concepto")
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    if let due = charge.dueAt {
                        LabeledContent {
                            Text(due, style: .date)
                                .foregroundStyle(charge.isOverdue ? Color.ruulNegative : Color.primary)
                        } label: {
                            Text("Vence")
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    LabeledContent {
                        Text(debtorName)
                            .foregroundStyle(Color.primary)
                    } label: {
                        Text("De")
                            .foregroundStyle(Color.secondary)
                    }
                }

                Section {
                    Picker("Pagado por", selection: $payerMemberId) {
                        ForEach(members, id: \.member.id) { row in
                            Text(row.displayName).tag(row.member.id)
                        }
                    }
                } footer: {
                    if payerMemberId != charge.owedByMemberId {
                        Text("Estás cubriendo la cuota de otro miembro. El pago se atribuye al pool, pero la auditoría guarda que tú pusiste el dinero.")
                            .font(.caption)
                    } else {
                        Text("Por defecto paga la persona a la que se le cobró.")
                            .font(.caption)
                    }
                }

                Section("Nota (opcional)") {
                    TextField("ej: pagado por Bizum", text: $note, axis: .vertical)
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
            .ruulSheetToolbar("Pagar cuota")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonLabel) {
                        RuulHaptic.light.trigger()
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || successPhrase != nil)
                }
            }
            .sensoryFeedback(.success, trigger: successPhrase)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
    }

    private var debtorName: String {
        members.first(where: { $0.member.id == charge.owedByMemberId })?.displayName ?? "Miembro"
    }

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Registrando…" }
        return "Pagar \(formattedCents(charge.amountCents))"
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // paid_by only travels when ≠ owed_by — keeps the audit signal
        // meaningful (default case omits it).
        let resolvedPayer: UUID? = (payerMemberId == charge.owedByMemberId)
            ? nil
            : payerMemberId
        do {
            _ = try await app.ledgerRepo.payPoolCharge(
                obligationId: charge.id,
                paidByMemberId: resolvedPayer,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                clientId: clientId
            )
            isSubmitting = false
            successPhrase = "Cuota pagada"
            try? await Task.sleep(for: .milliseconds(700))
            onDidPay()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            RuulHaptic.error.trigger()
        }
    }

    private func formattedCents(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = charge.currency
        f.locale = Locale(identifier: "es_MX")
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(charge.currency) \(cents / 100)"
    }
}
