import SwiftUI
import RuulCore
import RuulUI

/// FASE 4 Wave 4 (2026-05-25): reimbursement sheet. Cuando el pool
/// le devuelve dinero a un miembro que pagó algo del grupo, escribe
/// un `reimbursement` ledger entry con `from=picked_member, to=NULL`.
///
/// Por qué la dirección invertida (from=member, to=NULL):
/// El `expense` original (RecordSharedExpenseSheet) escribió
/// `from=NULL, to=member` → received_cents += amount → net positive
/// ("el grupo te debe X"). Para CANCELAR ese receivable con la mesa de
/// proyecciones existente (mig 00136 simple sent/received), el
/// reimbursement debe sumar a `sent_cents` del miembro — la única
/// forma sin tocar la vista server-side es escribir `from=member`.
///
/// Pool balance NO se afecta — el `group_money_summary_view` solo
/// suma `contribution` y `expense`. `reimbursement` queda fuera
/// (la doctrina dice: el expense ya contó la salida cuando se
/// registró; el reimbursement solo settles el receivable).
///
/// V1 caveat: cualquier miembro puede recordar este movimiento. RLS
/// del backend solo gate por `record_ledger_entry` que acepta a
/// cualquier miembro del grupo.
@MainActor
public struct ReimburseMemberSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    public let members: [MemberWithProfile]
    /// Member pre-seleccionado (típicamente el viewer cobrando lo que
    /// le deben). Nil → user picks.
    public let suggestedMemberId: UUID?
    public let suggestedAmountCents: Int64?
    public let onDidReimburse: () -> Void

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
        suggestedAmountCents: Int64? = nil,
        onDidReimburse: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.members = members
        self.suggestedMemberId = suggestedMemberId
        self.suggestedAmountCents = suggestedAmountCents
        self.onDidReimburse = onDidReimburse
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
                    Text("Reembolso")
                } footer: {
                    Text("El pool le devuelve dinero al miembro. No cambia el saldo del pool (el gasto original ya lo contó), solo cancela lo que el grupo le debía.")
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
            .ruulSheetToolbar("Reembolsar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Registrando…" : "Reembolsar") {
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
                if amountText.isEmpty, let cents = suggestedAmountCents, cents > 0 {
                    // .grouping(.never) — la formatter por default mete
                    // separadores de miles ("58,000,750") que rompen
                    // `Decimal(string:)` al parsear. Sin grouping, el
                    // texto queda como "58000750" parseable.
                    amountText = (Decimal(cents) / 100).formatted(
                        .number.precision(.fractionLength(0)).grouping(.never)
                    )
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

        var metadata: [String: JSONConfig] = [
            "client_id": .string(clientId.uuidString)
        ]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            metadata["note"] = .string(trimmed)
        }

        do {
            _ = try await app.ledgerRepo.recordEntry(
                groupId: groupId,
                resourceId: nil,
                type: LedgerEntry.Kind.reimbursement,
                amountCents: cents,
                // Direction inverted on purpose — see file header.
                fromMemberId: memberId,
                toMemberId: nil,
                currency: currency,
                metadata: .object(metadata)
            )
            successPhrase = "Reembolsaste \(formattedAmount(cents)) a \(name)"
            try? await Task.sleep(for: .milliseconds(700))
            onDidReimburse()
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
