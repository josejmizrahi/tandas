import SwiftUI
import RuulUI
import RuulCore

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
public struct EditRuleSheet: View {
    public let rule: GroupRule
    public let pending: PendingVote?
    /// Phase G3: when the sheet is opened from a deep link (push tap or
    /// inbox `ruleChangeApplyPending`), seed the draft amount with the
    /// vote-approved value so Save is one tap away. Defaults to nil for
    /// the existing pencil → tap rule flow which seeds from
    /// `FineConsequenceParser.shape(of: rule.consequences)`.
    public let prefilledAmount: Int?
    /// Phase G3: when the sheet is opened from an inbox row, this is the
    /// `UserAction.id` that surfaced it. After a successful save the
    /// coordinator resolves the action so the inbox row disappears. nil
    /// for any non-inbox entry path (deep link without inbox, pencil flow).
    public let pendingActionId: UUID?
    @Bindable var coordinator: EditRulesCoordinator
    public let onDismiss: () -> Void
    @Environment(AppState.self) private var app

    @State private var draftAmount: String = ""
    @FocusState private var amountFocused: Bool
    @State private var showArchiveConfirm: Bool = false
    /// Composer presentation handle when user opens the full
    /// edit-in-place flow (§22.1 / mig 00247). Bumps version+1 under
    /// the same rule_id + slug so atom history stays continuous.
    @State private var composerCoord: RuleComposerCoordinator?

    public init(
        rule: GroupRule,
        pending: PendingVote?,
        prefilledAmount: Int? = nil,
        pendingActionId: UUID? = nil,
        coordinator: EditRulesCoordinator,
        onDismiss: @escaping () -> Void
    ) {
        self.rule = rule
        self.pending = pending
        self.prefilledAmount = prefilledAmount
        self.pendingActionId = pendingActionId
        self.coordinator = coordinator
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Form {
            Section { Text(rule.name).font(.title3.weight(.semibold)) }

            Section("Multa") { fineSection }

            if pending != nil {
                Section {
                    Text("Esta regla está siendo votada para archivar.")
                        .foregroundStyle(.orange)
                }
            } else {
                if canOpenComposer {
                    Section {
                        Button { openComposer() } label: {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                Text("Editar composición completa")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text("Cuándo, condiciones y qué pasa. Crea una nueva versión preservando el historial.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .ruulSheetToolbar("Editar regla", onClose: onDismiss)
        .fullScreenCover(item: $composerCoord) { coord in
            RuleComposerView(
                coord: coord,
                onPublished: { _ in
                    composerCoord = nil
                    Task { await coordinator.refresh() }
                    onDismiss()
                },
                onCancel: { composerCoord = nil }
            )
            .environment(app)
        }
        .toolbar {
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
            Text("Se abrirá una votación del grupo. Si pasa, '\(rule.name)' deja de aplicarse.")
        }
    }

    @ViewBuilder
    private var fineSection: some View {
        switch FineConsequenceParser.shape(of: rule.consequences) {
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
        if case .flat(let a) = FineConsequenceParser.shape(of: rule.consequences) { return a }
        return nil
    }

    private var isAmountDirty: Bool {
        guard let current = currentFlatAmount,
              let drafted = Int(draftAmount.filter(\.isNumber)) else { return false }
        return drafted != current && drafted > 0 && drafted <= 1_000_000
    }

    private func seedDraft() {
        // Deep-link / inbox entry: prefilled value wins. Falls back to the
        // current flat amount for the pencil → tap-rule path.
        if let prefilledAmount {
            draftAmount = String(prefilledAmount)
        } else if let current = currentFlatAmount {
            draftAmount = String(current)
        }
    }

    private func commitAmount() async {
        guard let drafted = Int(draftAmount.filter(\.isNumber)),
              drafted > 0 && drafted <= 1_000_000 else { return }
        await coordinator.setFlatFineAmount(rule: rule, amount: drafted)
        // Phase G3: when entered from inbox `ruleChangeApplyPending`,
        // resolve the action so the row disappears on next refresh.
        if let pendingActionId {
            await coordinator.resolvePendingAction(pendingActionId)
        }
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

    // MARK: - Composer entry (full edit-in-place)

    /// True when the AppState wiring + governance allow opening the full
    /// composer. Hidden in preview/mock when ruleTemplateRepo is nil, and
    /// when the group's policy doesn't grant modifyRules to this actor
    /// (the coordinator already filters at that level, but we re-check
    /// to avoid surfacing an inert button).
    private var canOpenComposer: Bool {
        app.ruleTemplateRepo != nil
        && app.groups.contains(where: { $0.id == rule.groupId })
    }

    private func openComposer() {
        guard let repo = app.ruleTemplateRepo,
              let group = app.groups.first(where: { $0.id == rule.groupId }) else {
            return
        }
        composerCoord = RuleComposerCoordinator(
            group: group,
            shapeRegistry: app.ruleShapeRegistry,
            repo: repo,
            editing: rule
        )
    }
}
