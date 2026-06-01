import SwiftUI
import RuulCore

/// Pay-a-monetary-sanction form. Thin variant of `RecordSettlementSheet`
/// tailored to a specific `GroupSanction` row (Primitiva 11) — the
/// amount comes pre-filled from the sanction and the destination is
/// always the pool. Notes are pre-seeded with the sanction reason so
/// the resulting settlement row carries useful context.
///
/// Wire-level this is still `record_settlement(target: .pool, ...)` —
/// monetary sanctions create a `group_obligations` row on the pool,
/// and paying the pool with the sanction's amount closes it.
struct PaySanctionSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let sanction: GroupSanction
    let onPaid: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String
    @State private var notes: String
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var clientId: String?
    /// V2-G5 — see RecordExpenseSheet.selectedMandateId.
    @State private var selectedMandateId: UUID?
    /// V2-G4.1 — payment progress hidratado on appear. nil = aún cargando.
    @State private var paymentStatus: SanctionPaymentStatus?

    init(
        container: DependencyContainer,
        groupId: UUID,
        myMembershipId: UUID,
        sanction: GroupSanction,
        onPaid: @escaping () -> Void
    ) {
        self.container = container
        self.groupId = groupId
        self.myMembershipId = myMembershipId
        self.sanction = sanction
        self.onPaid = onPaid
        let amount = sanction.amount ?? 0
        // Pre-fill se ajusta a outstanding cuando el RPC termine; mientras
        // tanto usa el monto original como fallback.
        self._amountText = State(initialValue: amount > 0 ? "\(amount)" : "")
        self._notes = State(initialValue: "Pago de sanción: \(sanction.reason)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.PaySanction.summarySection) {
                    LabeledContent {
                        Text(sanction.kind.label)
                    } label: {
                        Text("Tipo")
                    }
                    LabeledContent {
                        Text(sanction.reason)
                            .lineLimit(3)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Razón")
                    }
                    if let status = paymentStatus, status.hasObligation {
                        progressRow(status: status)
                    }
                }

                Section(L10n.PaySanction.amountSection) {
                    TextField(String(localized: L10n.PaySanction.amountField), text: $amountText)
                        .keyboardType(.decimalPad)
                    if let status = paymentStatus,
                       status.amountOutstanding > 0,
                       parsedAmount != status.amountOutstanding {
                        Button {
                            amountText = formatAmount(status.amountOutstanding)
                        } label: {
                            Label(
                                "Pagar todo (\(formatAmount(status.amountOutstanding)))",
                                systemImage: "checkmark.circle"
                            )
                            .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }

                Section(L10n.PaySanction.notesSection) {
                    TextField(
                        String(localized: L10n.PaySanction.notesPlaceholder),
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }

                MandateBehalfPickerSection(
                    selection: $selectedMandateId,
                    availableMandates: availableMandates
                )
            }
            .navigationTitle(L10n.PaySanction.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await container.mandatesStore.refreshIfNeeded(groupId: groupId)
                await loadPaymentStatus()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.PaySanction.cancelButton)) {
                        clientId = nil
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.PaySanction.confirmButton)
                        }
                    }
                    .disabled(!isFormValid || isSubmitting)
                }
            }
            .alert(
                error?.title ?? "",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                actions: { Button("OK") { error = nil } },
                message: { Text(error?.message ?? "") }
            )
        }
    }

    private var availableMandates: [GroupMandate] {
        container.mandatesStore.availableMandates(
            representativeMembershipId: myMembershipId,
            scope: .money
        )
    }

    private var parsedAmount: Decimal? {
        let normalized = amountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        return value > 0 ? value : nil
    }

    private var isFormValid: Bool { parsedAmount != nil }

    @ViewBuilder
    private func progressRow(status: SanctionPaymentStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pendiente")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(formatAmount(status.amountOutstanding)) de \(formatAmount(status.amountOriginal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            ProgressView(value: status.progress)
                .tint(.accentColor)
        }
        .padding(.vertical, 2)
    }

    private func formatAmount(_ value: Decimal) -> String {
        let n = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? "\(value)"
    }

    private func loadPaymentStatus() async {
        do {
            let status = try await container.sanctionsRepository.paymentStatus(sanctionId: sanction.id)
            paymentStatus = status
            // Pre-fill el campo con outstanding si todavía no se editó.
            if status.amountOutstanding > 0,
               let current = parsedAmount,
               current == (sanction.amount ?? 0),
               current != status.amountOutstanding {
                amountText = formatAmount(status.amountOutstanding)
            }
        } catch {
            // Silent — sheet sigue funcional con el monto original.
        }
    }

    private func submit() async {
        guard let amount = parsedAmount else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if clientId == nil { clientId = UUID().uuidString }
        do {
            if selectedMandateId == nil {
                // V3 PARTE 5a — self-party sugar. Backend resuelve target,
                // pool target_kind, rechaza over-pay (cap en outstanding).
                _ = try await container.sanctionsRepository.paySanction(
                    sanctionId: sanction.id,
                    amount: amount,
                    unit: nil,
                    clientId: clientId
                )
            } else {
                // Mandate-on-behalf: el target del sanction NO es el caller,
                // así que pay_sanction lo rechazaría con 42501. Mantenemos
                // record_settlement para que el mandato lleve la autoridad.
                let notesClean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                let draft = SettlementDraft(
                    groupId: groupId,
                    paidByMembershipId: myMembershipId,
                    target: .pool,
                    amount: amount,
                    notes: notesClean.isEmpty ? nil : notesClean,
                    mandateId: selectedMandateId
                )
                _ = try await container.moneyRepository.recordOwnSettlement(draft, clientId: clientId)
            }
            clientId = nil
            onPaid()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }

}
