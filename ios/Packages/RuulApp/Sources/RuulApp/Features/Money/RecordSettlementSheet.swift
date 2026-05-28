import SwiftUI
import RuulCore

/// Self-party settlement form. Slice 5a adds a target picker so callers
/// can pay either the pool or a specific member they already owe (the
/// member options are derived from `MoneyStore.obligations`, now that
/// `member_obligation_summary` exposes `owed_to_membership_id` per
/// canonical_followup_25).
struct RecordSettlementSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var target: TargetOption = .pool
    @State private var amountText: String = ""
    @State private var notes: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var clientId: String?
    /// V2-G5 — see RecordExpenseSheet.selectedMandateId.
    @State private var selectedMandateId: UUID?

    private enum TargetOption: Hashable {
        case pool
        case member(id: UUID, label: String)

        var label: String {
            switch self {
            case .pool: return "Al grupo"
            case .member(_, let label): return label
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("¿A quién pagas?") {
                    Picker("Destino", selection: $target) {
                        Text("Al grupo (pool)").tag(TargetOption.pool)
                        ForEach(memberOptions, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Cuánto") {
                    TextField("Monto en MXN", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Notas (opcional)") {
                    TextField("¿De qué pago es?", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                MandateBehalfPickerSection(
                    selection: $selectedMandateId,
                    availableMandates: availableMandates
                )

                if memberOptions.isEmpty {
                    Section {
                        Text("Solo puedes liquidar al grupo por ahora. Cuando alguien te preste dinero, ese miembro aparecerá aquí.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Liquidar")
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

    /// V2-G5 — see RecordExpenseSheet.availableMandates.
    private var availableMandates: [GroupMandate] {
        container.mandatesStore.availableMandates(
            representativeMembershipId: myMembershipId,
            scope: .money
        )
    }

    /// Distinct member counterparties pulled from the open obligations.
    /// One obligation per person can show up multiple times in the store
    /// (e.g. two separate expenses → two rows owed to the same person);
    /// we collapse by membership id so the picker stays tight.
    private var memberOptions: [TargetOption] {
        var seen: Set<UUID> = []
        var options: [TargetOption] = []
        for obligation in container.moneyStore.obligations
        where obligation.owedToKind == "member" {
            guard let id = obligation.owedToMembershipId, !seen.contains(id) else { continue }
            seen.insert(id)
            options.append(.member(id: id, label: obligation.owedToLabel))
        }
        return options
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

        let settlementTarget: SettlementTarget
        switch target {
        case .pool:
            settlementTarget = .pool
        case .member(let id, _):
            settlementTarget = .member(membershipId: id)
        }

        let draft = SettlementDraft(
            groupId: groupId,
            paidByMembershipId: myMembershipId,
            target: settlementTarget,
            amount: amount,
            notes: notesClean.isEmpty ? nil : notesClean,
            mandateId: selectedMandateId
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
