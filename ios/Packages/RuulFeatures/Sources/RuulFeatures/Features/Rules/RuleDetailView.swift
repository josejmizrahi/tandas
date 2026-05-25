import SwiftUI
import RuulUI
import RuulCore

/// Detail de una regla del grupo. Doctrine v2 (2026-05-25): renderiza
/// vía `ResourceDetailContent` para que la regla viva en el mismo
/// mundo visual que Event/Fund/Fine/Slot. Vocabulario humanizado:
/// "Multa escalante" → frase en humano, scope label sin slug leak.
public struct RuleDetailView: View {
    @Environment(AppState.self) private var app
    public let rule: GroupRule
    public let canEditRules: Bool
    /// If non-nil, a repeal or change vote is open for this rule. Used to
    /// block "Editar parámetros" while a vote is in flight (editing params
    /// while a vote is pending would create a superseding version that races
    /// with the vote outcome). Defaults to nil for callers that don't track
    /// pending votes (e.g. previews, non-admin paths).
    public let pendingVote: PendingVote?
    public let onEdit: () -> Void
    public let onProposeChange: () -> Void

    public init(
        rule: GroupRule,
        canEditRules: Bool,
        pendingVote: PendingVote? = nil,
        onEdit: @escaping () -> Void,
        onProposeChange: @escaping () -> Void
    ) {
        self.rule = rule
        self.canEditRules = canEditRules
        self.pendingVote = pendingVote
        self.onEdit = onEdit
        self.onProposeChange = onProposeChange
    }

    @State private var paramsCoordinator: EditRuleParamsCoordinator?

    /// Looks up the `RuleBuilderTemplate` for this rule by matching `rule.slug`
    /// to `template.id`. Returns nil when the rule has no slug or the template
    /// isn't in the in-memory catalog (module-seeded or legacy rules).
    private var templateForRule: RuleBuilderTemplate? {
        guard let slug = rule.slug else { return nil }
        return app.ruleTemplates.first(where: { $0.id == slug })
    }

    public var body: some View {
        ResourceDetailContent(config: makeConfig())
            .navigationTitle("Regla")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $paramsCoordinator) { coord in
                EditRuleParamsSheet(coordinator: coord)
                    .environment(app)
            }
    }

    // MARK: - Config

    private func makeConfig() -> ResourceConfig {
        ResourceConfig.rule(
            RuleInput(
                id: rule.id.uuidString,
                name: rule.name,
                isActive: rule.isActive,
                scopeLabel: scopeLabel(rule),
                consequenceLines: humanConsequences,
                amountHero: amountHero,
                canEditRule: canEditRules,
                canEditParams: canEditParams,
                editParamsBlockedReason: editParamsBlockedReason,
                activity: []
            ),
            onEdit: onEdit,
            onEditParams: { openParamsEditor() },
            onProposeChange: onProposeChange
        )
    }

    // MARK: - Derived

    private var canEditParams: Bool {
        canEditRules && templateForRule != nil && app.ruleTemplateRepo != nil
    }

    private var editParamsBlockedReason: String? {
        guard canEditParams, pendingVote != nil else { return nil }
        return "Hay un cambio en votación — espera al resultado."
    }

    private var amountHero: RuleInput.AmountHero? {
        guard let amount = FineConsequenceParser.firstAmountMXN(in: rule.consequences),
              amount > 0 else {
            return nil
        }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        let formatted = nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
        return RuleInput.AmountHero(value: formatted, label: "Multa")
    }

    private var humanConsequences: [String] {
        rule.consequences.map(humanConsequence)
    }

    private func openParamsEditor() {
        guard let template = templateForRule,
              let repo = app.ruleTemplateRepo else { return }
        paramsCoordinator = EditRuleParamsCoordinator(
            rule: rule,
            template: template,
            ruleTemplateRepo: repo
        )
    }

    /// Human-readable label for `rule.scope`. Per identity_context_doctrine
    /// §5 vocab: the module scope renders the registry's `name` instead of
    /// the slug ("Multas básicas" vs "basic_fines").
    private func scopeLabel(_ rule: GroupRule) -> String {
        switch rule.scope {
        case .group:
            return "Todo el grupo"
        case .module:
            let humanName: String? = rule.moduleKey.flatMap { key in
                ModuleRegistry.v1Fallback.modules.first(where: { $0.id == key })?.name
            }
            return humanName ?? "Función del grupo"
        case .series:
            return "Toda la recurrencia"
        case .resource:
            return "Sólo este recurso"
        case .membership:
            return "Por miembro"
        }
    }

    /// Renderiza un `ConsequenceEnvelope` en español. Cubre `fine` con
    /// los dos shapes (flat / escalating) que la app entiende; otros
    /// tipos caen al raw para no ocultar info.
    private func humanConsequence(_ cons: GroupRule.ConsequenceEnvelope) -> String {
        switch cons.type {
        case "fine":
            if let flat = cons.config?.amount {
                return "Multa de \(formatMXN(flat))."
            }
            if let base = cons.config?.baseAmount,
               let step = cons.config?.stepAmount,
               let mins = cons.config?.stepMinutes {
                return "Empieza en \(formatMXN(base)) y sube \(formatMXN(step)) cada \(mins) minutos."
            }
            return "Multa con configuración personalizada."
        case .some(let raw):
            return raw
        case .none:
            return "Acción desconocida."
        }
    }

    private func formatMXN(_ amount: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}

#if DEBUG
#Preview("RuleDetailView") {
    NavigationStack {
        RuleDetailView(
            rule: GroupRule(
                id: UUID(),
                groupId: UUID(),
                slug: "dinner_late_arrival",
                name: "Llegada tardía",
                isActive: true,
                trigger: RuleTrigger(eventType: .checkInRecorded),
                conditions: [],
                consequences: [
                    GroupRule.ConsequenceEnvelope(
                        type: "fine",
                        config: GroupRule.ConsequenceEnvelope.Config(
                            amount: 250,
                            baseAmount: nil,
                            stepAmount: nil,
                            stepMinutes: nil
                        )
                    )
                ]
            ),
            canEditRules: true,
            onEdit: {},
            onProposeChange: {}
        )
    }
}
#endif
