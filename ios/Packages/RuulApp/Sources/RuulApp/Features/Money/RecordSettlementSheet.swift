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
    /// V3-SE-1 — optional prefill so callers (e.g. `SettleUpView`'s
    /// "Págale $X a Pedro" cards) can preselect the counterparty and
    /// amount. Default nil keeps the open-from-dashboard flow intact.
    let prefill: Prefill?
    let onSubmitted: () -> Void

    /// V3-SE-1 prefill payload. `counterpartyId == nil` means "pay the
    /// pool"; non-nil targets a specific peer member.
    struct Prefill: Equatable {
        let counterpartyId: UUID?
        let counterpartyLabel: String?
        let amount: Decimal?

        static let pool = Prefill(counterpartyId: nil, counterpartyLabel: nil, amount: nil)

        static func member(id: UUID, label: String, amount: Decimal?) -> Prefill {
            Prefill(counterpartyId: id, counterpartyLabel: label, amount: amount)
        }
    }

    init(
        container: DependencyContainer,
        groupId: UUID,
        myMembershipId: UUID,
        prefill: Prefill? = nil,
        onSubmitted: @escaping () -> Void
    ) {
        self.container = container
        self.groupId = groupId
        self.myMembershipId = myMembershipId
        self.prefill = prefill
        self.onSubmitted = onSubmitted
        // Seed state from prefill where present. Falls through to the
        // existing defaults (pool, blank amount) when prefill is nil.
        if let prefill {
            if let counterpartyId = prefill.counterpartyId {
                _target = State(initialValue: .member(
                    id: counterpartyId,
                    label: prefill.counterpartyLabel ?? "—"
                ))
            } else {
                _target = State(initialValue: .pool)
            }
            if let amount = prefill.amount {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.maximumFractionDigits = 2
                formatter.minimumFractionDigits = 0
                formatter.usesGroupingSeparator = false
                formatter.locale = Locale(identifier: "es_MX")
                _amountText = State(initialValue: formatter.string(from: amount as NSNumber) ?? "")
            }
        }
    }

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

    /// V3 doctrine_mandate_in_money_rpcs — espejo de
    /// RecordExpenseSheet.resolvedPaidByMembershipId. Cuando el
    /// mandato apunta a una membership específica, el settlement se
    /// registra como pagado por el principal. group/committee/role →
    /// caller queda como payer.
    private var resolvedPaidByMembershipId: UUID {
        guard let mandateId = selectedMandateId,
              let mandate = availableMandates.first(where: { $0.id == mandateId }),
              mandate.principalType == .membership,
              let principalId = mandate.principalId
        else {
            return myMembershipId
        }
        return principalId
    }

    /// Distinct member counterparties pulled from the open obligations.
    /// One obligation per person can show up multiple times in the store
    /// (e.g. two separate expenses → two rows owed to the same person);
    /// we collapse by membership id so the picker stays tight.
    ///
    /// V3-SE-1: when a prefilled counterparty isn't already in the open
    /// obligations (e.g. the SettleUp plan merged several into a single
    /// net suggestion), we still surface it so the picker can show the
    /// preselected option.
    private var memberOptions: [TargetOption] {
        var seen: Set<UUID> = []
        var options: [TargetOption] = []
        for obligation in container.moneyStore.obligations
        where obligation.owedToKind == "member" {
            guard let id = obligation.owedToMembershipId, !seen.contains(id) else { continue }
            seen.insert(id)
            options.append(.member(id: id, label: obligation.owedToLabel))
        }
        if let prefill, let prefilledId = prefill.counterpartyId, !seen.contains(prefilledId) {
            options.insert(.member(id: prefilledId, label: prefill.counterpartyLabel ?? "—"), at: 0)
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

        // V3 mandate redirect: si el mandato seleccionado representa a
        // una membership específica, el draft se firma como pagado
        // por el principal — no por mí. Audit symmetry con
        // RecordExpenseSheet.
        let draft = SettlementDraft(
            groupId: groupId,
            paidByMembershipId: resolvedPaidByMembershipId,
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
