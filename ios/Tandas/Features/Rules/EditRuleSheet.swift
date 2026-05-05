import SwiftUI

/// Sheet presented from `EditRulesView` when the user taps a rule card.
/// Shows the rule title + description (read-only "CÓMO FUNCIONA"), exposes
/// flat-amount editing with explicit Save gating, and surfaces an
/// "Archivar regla" destructive action that opens a `rule_repeal` vote
/// via `EditRulesCoordinator.openRepealVote`.
///
/// The current `GroupRule` model only carries the read-shape consequence
/// envelope and a textual `description`; the platform `Rule` (with
/// `RuleTrigger` / `[RuleCondition]`) is not yet projected onto the rules
/// list. C3 therefore renders the description as the "CÓMO FUNCIONA" copy
/// and defers the `RuleSummaryFormatter` integration to the sprint that
/// hydrates `GroupRule` with trigger + conditions.
struct EditRuleSheet: View {
    let rule: GroupRule
    let pending: PendingVote?
    @Bindable var coordinator: EditRulesCoordinator
    let onDismiss: () -> Void

    @State private var draftAmount: String = ""
    @FocusState private var amountFocused: Bool
    @State private var showArchiveConfirm: Bool = false

    var body: some View {
        Form {
            Section { Text(rule.title).font(.title3.weight(.semibold)) }

            if let desc = rule.description, !desc.isEmpty {
                Section("CÓMO FUNCIONA") {
                    Text(desc)
                }
            }

            Section("MULTA") { fineSection }

            if pending != nil {
                Section {
                    Text("Esta regla está siendo votada para archivar.")
                        .foregroundStyle(.orange)
                }
            } else {
                Section {
                    Button(role: .destructive) {
                        showArchiveConfirm = true
                    } label: {
                        HStack { Text("Archivar regla"); Spacer() }
                    }
                    Text("Abre votación del grupo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Editar regla")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { onDismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await commitAmount() } }
                    .disabled(!isAmountDirty || pending != nil)
            }
        }
        .onAppear(perform: seedDraft)
        .alert("¿Archivar regla?", isPresented: $showArchiveConfirm) {
            Button("Sí, abrir votación", role: .destructive) {
                Task { await openRepealVote() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se abrirá una votación del grupo. Si pasa, '\(rule.title)' deja de aplicarse.")
        }
    }

    @ViewBuilder
    private var fineSection: some View {
        switch rule.fineShape {
        case .flat:
            HStack {
                Text("Monto")
                Spacer()
                TextField("$0", text: $draftAmount)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($amountFocused)
                    .disabled(pending != nil)
            }
        case .escalating(let base, let step, let stepMinutes):
            VStack(alignment: .leading, spacing: 4) {
                Text("Base: \(formatMXN(base)) · cada \(stepMinutes) min suma \(formatMXN(step))")
                Text("Multas escalonadas se editan en una próxima versión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none, .unknown:
            Text("Configuración de multa no editable").foregroundStyle(.secondary)
        }
    }

    private var currentFlatAmount: Int? {
        if case .flat(let a) = rule.fineShape { return a }
        return nil
    }

    private var isAmountDirty: Bool {
        guard let current = currentFlatAmount,
              let drafted = Int(draftAmount.filter(\.isNumber)) else { return false }
        return drafted != current && drafted > 0 && drafted <= 1_000_000
    }

    private func seedDraft() {
        if let current = currentFlatAmount { draftAmount = String(current) }
    }

    private func commitAmount() async {
        guard let drafted = Int(draftAmount.filter(\.isNumber)),
              drafted > 0 && drafted <= 1_000_000 else { return }
        await coordinator.setFlatFineAmount(rule: rule, amount: drafted)
        amountFocused = false
        onDismiss()
    }

    private func openRepealVote() async {
        await coordinator.openRepealVote(rule: rule)
        onDismiss()
    }

    private func formatMXN(_ amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}
