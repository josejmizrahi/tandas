import SwiftUI
import RuulCore

/// Self-party settlement form, pool target only in 4b.
///
/// Member-to-member settlement is intentionally out of scope: the iOS
/// `ObligationSummary` doesn't expose the counterparty's membership id
/// (only a label), so we can't safely fill `p_paid_to_membership_id`
/// for `paid_to_kind = member` without inventing client-side
/// resolution. Pool covers the common "I owe the group" case and stays
/// within the firmed §16-bis contract.
struct RecordSettlementSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String = ""
    @State private var notes: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var clientId: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Cuánto") {
                    TextField("Monto en MXN", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Notas (opcional)") {
                    TextField("¿De qué pago es?", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    Text("Se aplica al fondo del grupo. Para liquidar con un miembro específico necesitas su ID — todavía no lo exponemos en la app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Liquidar al grupo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
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
                            Text("Liquidar")
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

    private var parsedAmount: Decimal? {
        let normalized = amountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        return value > 0 ? value : nil
    }

    private var isFormValid: Bool {
        parsedAmount != nil
    }

    private func submit() async {
        guard let amount = parsedAmount else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        if clientId == nil { clientId = UUID().uuidString }
        let notesClean = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        let draft = SettlementDraft(
            groupId: groupId,
            paidByMembershipId: myMembershipId,
            target: .pool,
            amount: amount,
            notes: notesClean.isEmpty ? nil : notesClean
        )
        do {
            _ = try await container.moneyRepository.recordOwnSettlement(draft, clientId: clientId)
            clientId = nil
            onSubmitted()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
