import SwiftUI
import RuulUI
import RuulCore

/// Detail view de una regla del grupo. Per DS v3 §6.4.
///
/// Muestra: hero (status pill + título + descripción + monto multa),
/// sección "Qué hace" (consequences rendered humano), timestamps
/// metadatos disponibles, y acciones (Editar / Proponer cambio) gated
/// por `canEditRules`.
///
/// Nota: el modelo read-only `GroupRule` (la única fuente que consume
/// `RulesCoordinator`) no incluye trigger ni conditions — esos viven en
/// las platform tables y no se proyectan aquí. Por eso la página se
/// concentra en lo que sí está disponible: monto, consequences, y
/// estado activo. Cuando la lectura del trigger/conditions se cablee a
/// futuro, agregar las secciones "Cuándo" y "Si" arriba de "Qué hace".
///
/// La rule se pasa por init (snapshot inmutable). Cambios live-tracking
/// requieren refrescar el `RulesCoordinator` del padre y re-pushear la
/// destination — V1 acepta esa stale window (rare race en práctica).
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
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                hero
                consequencesSection
                if canEditRules {
                    actionsSection
                }
                metadataFooter
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Regla")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $paramsCoordinator) { coord in
            EditRuleParamsSheet(coordinator: coord)
                .environment(app)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(spacing: RuulSpacing.xs) {
                Circle()
                    .fill(rule.isLive ? Color.green : Color(.tertiaryLabel))
                    .frame(width: 8, height: 8)
                Text(rule.isLive ? "Activa" : "Inactiva")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            Text(rule.name)
                .font(.title.weight(.semibold))
                .foregroundStyle(Color.primary)
            if let amount = FineConsequenceParser.firstAmountMXN(in: rule.consequences), amount > 0 {
                HStack {
                    Text("Multa")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Spacer()
                    RuulMoneyView(
                        amount: Decimal(amount),
                        currency: "MXN",
                        size: .large,
                        color: .negative
                    )
                }
                .padding(RuulSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        .fill(Color.red.opacity(0.15))
                )
                .padding(.top, RuulSpacing.sm)
            }
        }
    }

    // MARK: - Sections

    private var consequencesSection: some View {
        sectionContainer(title: "Qué hace") {
            if rule.consequences.isEmpty {
                Text("Aún no hay nada configurado.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    ForEach(Array(rule.consequences.enumerated()), id: \.offset) { _, cons in
                        consequenceRow(cons)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        sectionContainer(title: "Acciones") {
            VStack(spacing: RuulSpacing.xs) {
                RuulButton(
                    "Editar regla",
                    systemImage: "pencil",
                    style: .secondary,
                    fillsWidth: true,
                    action: onEdit
                )
                if let template = templateForRule,
                   let repo = app.ruleTemplateRepo {
                    if pendingVote != nil {
                        // Block param edits while a repeal/change vote is open.
                        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                            RuulButton(
                                "Editar parámetros",
                                systemImage: "slider.horizontal.3",
                                style: .secondary,
                                fillsWidth: true,
                                action: {}
                            )
                            .disabled(true)
                            .opacity(0.5)
                            Text("Hay un cambio en votación — espera al resultado")
                                .font(.caption)
                                .foregroundStyle(Color(.tertiaryLabel))
                                .padding(.horizontal, RuulSpacing.xs)
                        }
                    } else {
                        RuulButton(
                            "Editar parámetros",
                            systemImage: "slider.horizontal.3",
                            style: .secondary,
                            fillsWidth: true,
                            action: {
                                paramsCoordinator = EditRuleParamsCoordinator(
                                    rule: rule,
                                    template: template,
                                    ruleTemplateRepo: repo
                                )
                            }
                        )
                    }
                }
                RuulButton(
                    "Proponer cambio al grupo",
                    systemImage: "text.bubble",
                    style: .plain,
                    fillsWidth: true,
                    action: onProposeChange
                )
            }
        }
    }

    private var metadataFooter: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let slug = rule.slug, !slug.isEmpty {
                metadataRow(label: "Slug", value: slug)
            }
            metadataRow(label: "Aplica a", value: scopeLabel(rule))
            metadataRow(
                label: "Estado",
                value: rule.isActive ? "Activa" : "Deshabilitada"
            )
        }
        .padding(.top, RuulSpacing.lg)
    }

    /// Human-readable label for `rule.scope`. The detail view always shows
    /// it (unlike the list, which hides the chip for group-scoped rules)
    /// so the reader sees "Aplica a: Grupo" explicitly when that's the
    /// case, not by omission.
    private func scopeLabel(_ rule: GroupRule) -> String {
        switch rule.scope {
        case .group:      return "Todo el grupo"
        case .module:     return rule.moduleKey.map { "Función · \($0)" } ?? "Función"
        case .series:     return "Toda la recurrencia"
        case .resource:   return "Esta instancia"
        case .membership: return "Por miembro"
        }
    }

    // MARK: - Rendering helpers

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
            content()
                .padding(RuulSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )
        }
    }

    private func consequenceRow(_ cons: GroupRule.ConsequenceEnvelope) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color.red)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(humanConsequence(cons))
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color(.tertiaryLabel))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(Color.secondary)
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
                return "Multa escalante: \(formatMXN(base)) base + \(formatMXN(step)) cada \(mins) min."
            }
            return "Multa (configuración personalizada)."
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
