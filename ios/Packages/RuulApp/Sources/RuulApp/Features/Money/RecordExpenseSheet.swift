import SwiftUI
import RuulCore

/// Self-party expense form. Hardcodes Foundation invariants:
///
/// - `paidBy = caller's membership in this group`
/// - `resourceId = nil` (shared pool, doctrine_shared_money)
/// - `split = .even` (custom split is a slice 5 add-on)
/// - `currency = MXN` (V1 single currency)
///
/// Mints a `p_client_id` once on the first submit and reuses it across
/// retries so a flaky network can't double-post the same expense
/// (doctrine §15 / dev contract idempotency clause).
struct RecordExpenseSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String = ""
    @State private var description: String = ""
    @State private var inKind: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    /// Stable across retries — minted on first submit attempt, reset on
    /// successful commit. Cancel discards it.
    @State private var clientId: String?
    /// V2-G5 — when the caller holds an active mandate they may record
    /// the expense on someone else's behalf. `nil` = acting in their
    /// own name (default).
    @State private var selectedMandateId: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Cuánto") {
                    TextField("Monto en MXN", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Detalles (opcional)") {
                    TextField("¿De qué fue?", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("Fue en especie", isOn: $inKind)
                }

                MandateBehalfPickerSection(
                    selection: $selectedMandateId,
                    availableMandates: availableMandates
                )

                Section {
                    Text("Se reparte parejo entre todos los miembros del grupo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Registrar gasto")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await container.mandatesStore.refreshIfNeeded(groupId: groupId)
            }
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
                            Text("Registrar")
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

    /// Active mandates that authorize *me* (the caller) to act on
    /// someone else's behalf in the money scope. Empty list collapses
    /// the picker section in `MandateBehalfPickerSection`.
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

    private var isFormValid: Bool {
        parsedAmount != nil
    }

    private func submit() async {
        guard let amount = parsedAmount else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        if clientId == nil { clientId = UUID().uuidString }
        let descriptionClean = description.trimmingCharacters(in: .whitespacesAndNewlines)

        let draft = ExpenseDraft(
            groupId: groupId,
            resourceId: nil,
            amount: amount,
            paidByMembershipId: myMembershipId,
            description: descriptionClean.isEmpty ? nil : descriptionClean,
            split: .even,
            inKind: inKind,
            mandateId: selectedMandateId
        )
        do {
            _ = try await container.moneyRepository.recordOwnExpense(draft, clientId: clientId)
            clientId = nil
            onSubmitted()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
