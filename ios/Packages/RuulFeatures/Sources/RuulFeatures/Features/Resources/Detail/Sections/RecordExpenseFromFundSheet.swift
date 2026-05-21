import SwiftUI
import RuulCore
import RuulUI

/// Expense sheet — invoked from the fund detail view's secondary menu
/// ("Registrar gasto"). Records a payout from the fund to a recipient
/// member via `fundRepo.recordExpense` → `fund_record_expense` RPC
/// (mig 00202, paid_by added in mig 00355).
///
/// Tri-role model (per ledger tri-role doctrine 2026-05-21):
///   - `recorded_by` = auth.uid(), stamped server-side. Not user input.
///   - `paid_by_member_id` = who fronted the cash. Defaults to the
///     current user; user can pick any active group member ("Daniel
///     registra que María pagó los bocadillos").
///   - `to_member_id` = who receives the money out of the fund.
///     Defaults to the same person as `paid_by` (the typical
///     reimbursement case) — user can override.
///
/// Submit path:
///   `FundRepository.recordExpense(fundId, amountCents, toMemberId,
///   currency, note, sourceEventId, clientId, paidByMemberId)` →
///   `fund_record_expense` RPC → `record_ledger_entry`
///   (type='expense', from=NULL, to=toMemberId,
///   metadata.paid_by_member_id=paidByMemberId, resource_id=fund) →
///   `fund_balance_view` reflects the new balance.
public struct RecordExpenseFromFundSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let fundId: UUID
    public let fundName: String
    public let currency: String
    public let members: [MemberWithProfile]
    /// When set, the entry is attributed to a specific event (mig 00344
    /// p_source_event_id) so the event's money tab can scope its
    /// projection without duplicating the fund per event.
    public let sourceEventId: UUID?
    public let sourceEventName: String?
    /// Called after a successful expense record so the caller can refresh
    /// the balance card.
    public let onDidRecord: () -> Void

    @State private var paidByMemberId: UUID?
    @State private var toMemberId: UUID?
    /// True once the user has manually picked a destinatario. Stops the
    /// auto-mirror from `paidByMemberId` so explicit overrides stick
    /// when the payer changes afterward.
    @State private var toMemberManuallySet: Bool = false
    @State private var amountText: String = ""
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    /// Stable idempotency key (mig 00351). Same retry-safety semantics as
    /// ContributeToFundSheet — generated per sheet open, reused on re-tap.
    @State private var clientId: UUID = UUID()

    public init(
        fundId: UUID,
        fundName: String,
        currency: String,
        members: [MemberWithProfile],
        sourceEventId: UUID? = nil,
        sourceEventName: String? = nil,
        onDidRecord: @escaping () -> Void
    ) {
        self.fundId = fundId
        self.fundName = fundName
        self.currency = currency
        self.members = members
        self.sourceEventId = sourceEventId
        self.sourceEventName = sourceEventName
        self.onDidRecord = onDidRecord
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fundName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    if let sourceEventName {
                        Label("Gasto de \(sourceEventName)", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } footer: {
                    Text(sourceEventName != nil
                         ? "El gasto sale del fondo y queda asociado a este evento."
                         : "El gasto sale del fondo y se acredita al destinatario.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    Picker("¿Quién pagó?", selection: $paidByMemberId) {
                        Text("Elige…").tag(Optional<UUID>.none)
                        ForEach(members) { m in
                            Text(m.displayName).tag(Optional(m.member.id))
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Por defecto eres tú. Cámbialo si alguien más lo pagó de su bolsa.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    Picker("Reembolsar a", selection: $toMemberId) {
                        Text("Elige…").tag(Optional<UUID>.none)
                        ForEach(members) { m in
                            Text(m.displayName).tag(Optional(m.member.id))
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Quién recibe el dinero del fondo. Por defecto la misma persona que pagó.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
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
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .ruulSheetToolbar("Registrar gasto")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Registrando…" : "Registrar") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting
                              || paidByMemberId == nil
                              || toMemberId == nil
                              || amountCents == nil)
                }
            }
            .task(id: app.session?.user.id) {
                seedDefaults()
            }
            .onChange(of: paidByMemberId) { _, newValue in
                if !toMemberManuallySet { toMemberId = newValue }
            }
            .onChange(of: toMemberId) { oldValue, newValue in
                // Detect a true user override — ignore the mirror writes
                // that originate from the paidBy change above, since
                // those land with newValue == paidByMemberId.
                if newValue != nil && newValue != paidByMemberId {
                    toMemberManuallySet = true
                }
            }
        }
    }

    /// Seeds `paidByMemberId` (and the mirrored `toMemberId`) from the
    /// session-resolved current member. Re-runs when the session id
    /// changes — covers the rare race where the sheet opens before
    /// `app.session` has hydrated.
    @MainActor
    private func seedDefaults() {
        guard paidByMemberId == nil else { return }
        guard let uid = app.session?.user.id,
              let me = members.first(where: { $0.member.userId == uid })?.member.id else {
            return
        }
        paidByMemberId = me
        if !toMemberManuallySet { toMemberId = me }
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
        guard let cents = amountCents,
              let toId = toMemberId,
              let paidById = paidByMemberId else { return }
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
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                sourceEventId: sourceEventId,
                clientId: clientId,
                paidByMemberId: paidById
            )
            onDidRecord()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
