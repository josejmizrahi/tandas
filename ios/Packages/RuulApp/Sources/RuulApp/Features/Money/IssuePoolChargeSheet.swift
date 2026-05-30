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

    /// V3 — multi-target. Set vacío = no se cobra a nadie. Soporta
    /// hasta 100 targets (backend guard); UI no impone limit.
    @State private var selectedTargetIds: Set<UUID> = []
    @State private var amountText: String = ""
    @State private var reason: String = ""
    @State private var selectedKind: ChargeKind = .quota
    @State private var selectedMandateId: UUID?
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?
    @State private var clientIdBase: String?

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

                Section {
                    if eligibleTargets.isEmpty {
                        Text("No hay miembros activos para cobrar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(eligibleTargets, id: \.id) { item in
                            targetRow(for: item)
                        }
                    }
                } header: {
                    HStack {
                        Text("A quién le cobras")
                        Spacer()
                        if !eligibleTargets.isEmpty {
                            Button(allSelected ? "Quitar todos" : "Todos") {
                                toggleAll()
                            }
                            .font(.footnote)
                        }
                    }
                } footer: {
                    if selectedTargetIds.isEmpty {
                        Text("Selecciona al menos un miembro.")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    } else if let summary = batchSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    Text(effectExplainer)
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
                        clientIdBase = nil
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
        !selectedTargetIds.isEmpty && parsedAmount != nil
    }

    private var allSelected: Bool {
        let allIds = Set(eligibleTargets.compactMap(\.membershipId))
        return !allIds.isEmpty && allIds == selectedTargetIds
    }

    /// Pluraliza el resumen del batch: "1 miembro · $50" / "3 miembros
    /// · $150 total". Visible cuando hay amount válido.
    private var batchSummary: String? {
        guard let amount = parsedAmount, !selectedTargetIds.isEmpty else { return nil }
        let count = selectedTargetIds.count
        let total = amount * Decimal(count)
        let label = count == 1 ? "1 miembro" : "\(count) miembros"
        return "\(label) · \(total.formatted()) MXN total"
    }

    private var effectExplainer: String {
        if selectedTargetIds.count <= 1 {
            return "Genera una deuda a favor del grupo. Cuando paguen, el balance del grupo crece."
        }
        return "Se crearán \(selectedTargetIds.count) deudas iguales, una por miembro. Si una falla (mandato vencido, miembro inactivo, etc.) ninguna se crea — la operación es atómica."
    }

    // MARK: - Mutations

    @ViewBuilder
    private func targetRow(for item: MembershipBoundaryItem) -> some View {
        if let mid = item.membershipId {
            Button {
                toggleTarget(mid)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedTargetIds.contains(mid)
                          ? "checkmark.circle.fill"
                          : "circle")
                        .foregroundStyle(selectedTargetIds.contains(mid)
                                         ? Color.accentColor
                                         : Color.secondary)
                    Text(item.displayName)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleTarget(_ id: UUID) {
        if selectedTargetIds.contains(id) {
            selectedTargetIds.remove(id)
        } else {
            selectedTargetIds.insert(id)
        }
    }

    private func toggleAll() {
        let allIds = Set(eligibleTargets.compactMap(\.membershipId))
        if allSelected {
            selectedTargetIds = []
        } else {
            selectedTargetIds = allIds
        }
    }

    // MARK: - Submit

    private func submit() async {
        guard let amount = parsedAmount, !selectedTargetIds.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if clientIdBase == nil { clientIdBase = UUID().uuidString }
        let reasonClean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = Array(selectedTargetIds)
        do {
            // V3: single target → record_pool_charge; multi target →
            // record_pool_charge_batch (atomic).
            if targets.count == 1 {
                _ = try await container.moneyRepository.recordPoolCharge(
                    groupId: groupId,
                    targetMembershipId: targets[0],
                    amount: amount,
                    unit: "MXN",
                    chargeKind: selectedKind.rawValue,
                    reason: reasonClean.isEmpty ? nil : reasonClean,
                    mandateId: selectedMandateId,
                    clientId: clientIdBase
                )
            } else {
                _ = try await container.moneyRepository.recordPoolChargeBatch(
                    groupId: groupId,
                    targetMembershipIds: targets,
                    amount: amount,
                    unit: "MXN",
                    chargeKind: selectedKind.rawValue,
                    reason: reasonClean.isEmpty ? nil : reasonClean,
                    mandateId: selectedMandateId,
                    clientIdBase: clientIdBase
                )
            }
            clientIdBase = nil
            onSubmitted()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
