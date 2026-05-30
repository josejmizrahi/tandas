import SwiftUI
import RuulCore

/// V3 — Cobrar cuota/buy-in/fee a un miembro.
///
/// Crea una obligation pool-side (owedTo=pool, kind='pool_charge') que
/// el target debe saldar via record_settlement to pool. NO retira
/// dinero del miembro automáticamente — solo emite la deuda. Cuando
/// el target paga, el pool crece.
///
/// Doctrina: usado para cuotas (mensualidad), buy-ins (capital
/// inicial) y fees genéricos. Permission `pool_charge.record`
/// gateada server-side (típicamente admin/fundador).
struct IssuePoolChargeSheet: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTargetId: UUID?
    @State private var amountText: String = ""
    @State private var reason: String = ""
    @State private var selectedKind: ChargeKind = .quota
    @State private var selectedMandateId: UUID?
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var clientId: String?

    enum ChargeKind: String, CaseIterable, Identifiable, Hashable {
        case quota = "quota"
        case buyIn = "buy_in"
        case fee   = "fee"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .quota: return "Cuota"
            case .buyIn: return "Buy-in"
            case .fee:   return "Fee"
            }
        }

        var subtitle: String {
            switch self {
            case .quota: return "Aporte recurrente esperado (ej: mensualidad)."
            case .buyIn: return "Capital inicial para entrar al grupo."
            case .fee:   return "Tarifa puntual genérica."
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo") {
                    Picker(selection: $selectedKind) {
                        ForEach(ChargeKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    } label: {
                        Text("Tipo de cobro")
                    }
                    Text(selectedKind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("A quién le cobras") {
                    if eligibleTargets.isEmpty {
                        Text("No hay miembros activos para cobrar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $selectedTargetId) {
                            Text("Selecciona…").tag(UUID?.none)
                            ForEach(eligibleTargets, id: \.id) { item in
                                Text(item.displayName).tag(Optional(item.membershipId!))
                            }
                        } label: {
                            Text("Miembro")
                        }
                    }
                }

                Section("Monto") {
                    TextField("Monto en MXN", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Motivo (opcional)") {
                    TextField("¿Por qué?", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                }

                MandateBehalfPickerSection(
                    selection: $selectedMandateId,
                    availableMandates: availableMandates
                )

                Section {
                    Text("Genera una deuda a favor del grupo. Cuando \(targetDisplayName) la pague, el balance del grupo crece.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cobrar cuota")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await container.mandatesStore.refreshIfNeeded(groupId: groupId)
                await container.membersStore.refreshIfNeeded(groupId: groupId)
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
                            Text("Cobrar")
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

    // MARK: - Derived

    private var eligibleTargets: [MembershipBoundaryItem] {
        container.membersStore.items.filter { item in
            item.kind == .membership
                && item.membershipId != nil
                && item.status == .active
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

    private var isFormValid: Bool {
        selectedTargetId != nil && parsedAmount != nil
    }

    private var targetDisplayName: String {
        guard let id = selectedTargetId,
              let item = eligibleTargets.first(where: { $0.membershipId == id })
        else { return "el miembro" }
        return item.displayName
    }

    // MARK: - Submit

    private func submit() async {
        guard let amount = parsedAmount, let targetId = selectedTargetId else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if clientId == nil { clientId = UUID().uuidString }
        let reasonClean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await container.moneyRepository.recordPoolCharge(
                groupId: groupId,
                targetMembershipId: targetId,
                amount: amount,
                unit: "MXN",
                chargeKind: selectedKind.rawValue,
                reason: reasonClean.isEmpty ? nil : reasonClean,
                mandateId: selectedMandateId,
                clientId: clientId
            )
            clientId = nil
            onSubmitted()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
