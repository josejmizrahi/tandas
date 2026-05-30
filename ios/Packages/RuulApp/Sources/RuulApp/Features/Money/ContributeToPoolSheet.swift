import SwiftUI
import RuulCore

/// V3 — Aportar dinero al pool del grupo.
///
/// Diferente de `RecordExpenseSheet`: una contribución NO genera
/// obligations peer-to-peer. El balance del grupo aumenta por `amount`
/// y el aportante queda registrado como `from_membership_id`. Caso
/// canonical: cuotas voluntarias, top-ups al fondo común, capital
/// inicial de un grupo nuevo.
///
/// Mandate-on-behalf cubierto via `resolvedFromMembershipId` (espejo
/// de RecordExpenseSheet.resolvedPaidByMembershipId).
struct ContributeToPoolSheet: View {
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
    @State private var selectedMandateId: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Cuánto aportas") {
                    TextField("Monto en MXN", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                Section("Detalles (opcional)") {
                    TextField(
                        "¿Para qué? (ej: aporte mensual, capital inicial)",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                }
                MandateBehalfPickerSection(
                    selection: $selectedMandateId,
                    availableMandates: availableMandates
                )
                Section {
                    Text(footerExplainer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Aportar al grupo")
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
                            Text("Aportar")
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

    private var availableMandates: [GroupMandate] {
        container.mandatesStore.availableMandates(
            representativeMembershipId: myMembershipId,
            scope: .money
        )
    }

    /// V3 doctrine_mandate_in_money_rpcs — mismo redirect que el
    /// resto de Money sheets. Si actúo via mandato de Alice, la
    /// contribución se registra a nombre de Alice (canonical fromBy
    /// en el ledger), no mío.
    private var resolvedFromMembershipId: UUID {
        guard let mandateId = selectedMandateId,
              let mandate = availableMandates.first(where: { $0.id == mandateId }),
              mandate.principalType == .membership,
              let principalId = mandate.principalId
        else {
            return myMembershipId
        }
        return principalId
    }

    private var parsedAmount: Decimal? {
        let normalized = amountText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Decimal(string: normalized) else { return nil }
        return value > 0 ? value : nil
    }

    private var isFormValid: Bool { parsedAmount != nil }

    private var footerExplainer: String {
        if selectedMandateId == nil {
            return "Tu aporte aumenta el balance del grupo. No genera deudas peer-to-peer."
        }
        return "Tu aporte aumenta el balance del grupo y queda registrado a nombre del principal del mandato."
    }

    // MARK: - Submit

    private func submit() async {
        guard let amount = parsedAmount else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if clientId == nil { clientId = UUID().uuidString }
        let notesClean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await container.moneyRepository.recordContribution(
                groupId: groupId,
                fromMembershipId: resolvedFromMembershipId,
                amount: amount,
                unit: "MXN",
                resourceId: nil,
                description: notesClean.isEmpty ? nil : notesClean,
                inKind: false,
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
