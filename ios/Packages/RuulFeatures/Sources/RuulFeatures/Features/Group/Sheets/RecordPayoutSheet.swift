import SwiftUI
import RuulCore
import RuulUI

/// FASE 4 Wave 4 Phase 3 Tier 2 (2026-05-25): "Pago del grupo a un
/// miembro" — capital returns, dividendos, stipends, devolución de
/// cuotas al salir.
///
/// Distinto de `ReimburseMemberSheet`:
///   * Reembolsar = cancelar un gasto que el miembro fronteó (cancela
///     receivable, no toca pool view). Convención: `from=member, to=NULL`.
///   * Pago del pool = capital flow del pool al miembro sin prior
///     receivable. Convención canónica: `from=NULL, to=member`.
///
/// Backend RPC: `record_payout` (mig 20260525233000). Idempotente vía
/// `client_id`.
@MainActor
public struct RecordPayoutSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    public let members: [MemberWithProfile]
    public let suggestedMemberId: UUID?
    public let onDidPayout: () -> Void

    @State private var selectedMemberId: UUID?
    @State private var amountText: String = ""
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var clientId: UUID = UUID()
    @State private var successPhrase: String?

    public init(
        groupId: UUID,
        currency: String,
        members: [MemberWithProfile],
        suggestedMemberId: UUID? = nil,
        onDidPayout: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.members = members
        self.suggestedMemberId = suggestedMemberId
        self.onDidPayout = onDidPayout
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("A quién", selection: $selectedMemberId) {
                        Text("Elegir miembro").tag(UUID?.none)
                        ForEach(members, id: \.member.id) { row in
                            Text(row.displayName).tag(Optional(row.member.id))
                        }
                    }
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
                    Text("Pago desde el pool")
                } footer: {
                    Text("El pool le entrega dinero al miembro: dividendo, retorno de capital, stipend, o devolución al salir del grupo. NO es para reembolsar un gasto fronteado (eso es \"Reembolsar\").")
                        .font(.caption)
                }

                Section {
                    TextField("Nota (opcional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
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
            .ruulSheetToolbar("Pagar desde el pool")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Registrando…" : "Pagar") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .sensoryFeedback(.success, trigger: successPhrase)
            .onAppear {
                if selectedMemberId == nil {
                    selectedMemberId = suggestedMemberId ?? members.first?.member.id
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.ultraThinMaterial)
    }

    private var canSubmit: Bool {
        guard selectedMemberId != nil else { return false }
        guard let amount = parsedAmount, amount > 0 else { return false }
        return true
    }

    private var parsedAmount: Decimal? {
        let normalized = amountText.replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalized)
    }

    @MainActor
    private func submit() async {
        guard let memberId = selectedMemberId,
              let amount = parsedAmount,
              amount > 0 else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let cents = NSDecimalNumber(decimal: amount * 100).int64Value
        let name = members.first(where: { $0.member.id == memberId })?.displayName ?? "Miembro"
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try await app.ledgerRepo.recordPayout(
                groupId: groupId,
                toMemberId: memberId,
                amountCents: cents,
                currency: currency,
                note: trimmed.isEmpty ? nil : trimmed,
                clientId: clientId
            )
            successPhrase = "Le pagaste \(formattedAmount(cents)) a \(name)"
            try? await Task.sleep(for: .milliseconds(700))
            onDidPayout()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formattedAmount(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
    }
}
