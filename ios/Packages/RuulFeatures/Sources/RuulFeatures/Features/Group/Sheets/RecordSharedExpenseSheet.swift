import SwiftUI
import RuulCore
import RuulUI

/// SharedMoney Phase 3 (brick 4): group-scoped expense sheet, invoked
/// from `SharedMoneyCard`'s "Registrar gasto" CTA in `GroupSpaceView`.
///
/// Mirrors the tri-role model of the legacy `RecordExpenseFromFundSheet`
/// (per ledger tri-role doctrine 2026-05-21):
///   - `recorded_by` = auth.uid(), stamped server-side. Not user input.
///   - `paid_by_member_id` = who fronted the cash. Defaults to current
///     user; overridable ("Daniel registra que María pagó").
///   - `to_member_id` = who gets reimbursed out of the pool. Defaults
///     to the same person as `paid_by`; overridable.
///
/// Unlike the legacy sheet, the caller supplies only `groupId` — the
/// wrapper RPC resolves the canonical shared pool internally (mig
/// 00363). Submit path:
///   `FundRepository.recordSharedExpense(groupId, amountCents,
///   toMemberId, currency, note, sourceResourceId, clientId,
///   paidByMemberId)` → `record_shared_expense` RPC →
///   `fund_record_expense` → `record_ledger_entry` (type='expense') →
///   `group_money_summary_view` reflects the new balance.
///
/// An expense on an empty/low pool drives the balance negative — a
/// valid IOU state for the group (founder decision 3, 2026-05-21).
public struct RecordSharedExpenseSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    public let members: [MemberWithProfile]
    /// When set, the entry is attributed to a specific resource
    /// (event/asset/space) via mig 00360 `p_source_resource_id`. Phase 4
    /// passes this from the resource Money Block; Phase 3 leaves it nil.
    public let sourceResource: (id: UUID, name: String)?
    /// Called after a successful expense record so the caller can
    /// refresh the shared pool summary.
    public let onDidRecord: () -> Void

    @State private var paidByMemberId: UUID?
    @State private var toMemberId: UUID?
    /// True once the user has manually picked a destinatario. Stops the
    /// auto-mirror from `paidByMemberId` so explicit overrides stick.
    @State private var toMemberManuallySet: Bool = false
    @State private var amountText: String = ""
    @State private var note: String = ""
    /// P4 (mig 00367): members who share this expense. Empty = no
    /// split (legacy 1-on-1 reimbursement flow). When non-empty,
    /// stamps `metadata.participants` and the UI surfaces the per-
    /// share = amount/N hint. V1 doesn't auto-generate IOUs from this
    /// list — users still settle manually via the existing flow.
    @State private var participantIds: Set<UUID> = []
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    /// Stable idempotency key (mig 00351). Generated per sheet open,
    /// reused on re-tap.
    @State private var clientId: UUID = UUID()

    public init(
        groupId: UUID,
        currency: String,
        members: [MemberWithProfile],
        sourceResource: (id: UUID, name: String)? = nil,
        onDidRecord: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.members = members
        self.sourceResource = sourceResource
        self.onDidRecord = onDidRecord
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let sourceResource {
                        Label("Gasto de \(sourceResource.name)", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } footer: {
                    Text(sourceResource != nil
                         ? "El gasto sale del dinero compartido y queda asociado a esto."
                         : "El gasto sale del dinero compartido y se acredita al destinatario.")
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

                Section("Monto (\(currency))") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                // P4 (mig 00367): multi-select participants. Empty list
                // = no split (legacy 1-on-1 path). Native `Toggle` rows
                // are taller than custom Button rows but match Apple
                // selection-list ergonomics (Settings/Files).
                Section {
                    ForEach(members) { m in
                        Toggle(
                            m.displayName,
                            isOn: Binding(
                                get: { participantIds.contains(m.member.id) },
                                set: { isOn in
                                    if isOn { participantIds.insert(m.member.id) }
                                    else { participantIds.remove(m.member.id) }
                                }
                            )
                        )
                    }
                } header: {
                    Text("Dividir entre")
                } footer: {
                    Text(splitFooter)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Section("Nota (opcional)") {
                    TextField("ej: Bocadillos para la junta", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                // "Reembolsar a" is collapsed by default — auto-mirror
                // to `paidByMemberId` covers the 95% case. Only power
                // users who need a different destinatario open this.
                Section {
                    DisclosureGroup("Más opciones") {
                        Picker("Reembolsar a", selection: $toMemberId) {
                            Text("Elige…").tag(Optional<UUID>.none)
                            ForEach(members) { m in
                                Text(m.displayName).tag(Optional(m.member.id))
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Quién recibe el dinero del fondo. Por defecto la misma persona que pagó.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
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
            .onChange(of: toMemberId) { _, newValue in
                if newValue != nil && newValue != paidByMemberId {
                    toMemberManuallySet = true
                }
            }
        }
    }

    /// Seeds `paidByMemberId` (and the mirrored `toMemberId`) from the
    /// session-resolved current member.
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
            _ = try await app.fundRepo.recordSharedExpense(
                groupId: groupId,
                amountCents: cents,
                toMemberId: toId,
                currency: currency,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                sourceResourceId: sourceResource?.id,
                clientId: clientId,
                paidByMemberId: paidById,
                participants: Array(participantIds)
            )
            onDidRecord()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// P4: live per-share = amount / N copy. Switches based on the
    /// selection cardinality so the section doesn't shout at the user
    /// before they pick anything.
    private var splitFooter: String {
        let count = participantIds.count
        if count == 0 {
            return "Si fue un gasto compartido, selecciona quiénes participan. Cada uno será responsable de su parte."
        }
        if count == 1 {
            return "Solo 1 participante seleccionado. Selecciona 2 o más para dividir el gasto."
        }
        guard let cents = amountCents else {
            return "\(count) participantes. Ingresa el monto para ver cuánto le toca a cada uno."
        }
        let share = Decimal(cents) / Decimal(count) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        let formatted = f.string(from: share as NSDecimalNumber) ?? "\(currency) \(Int(truncating: share as NSDecimalNumber))"
        return "\(count) participantes · cada uno: \(formatted)"
    }
}
