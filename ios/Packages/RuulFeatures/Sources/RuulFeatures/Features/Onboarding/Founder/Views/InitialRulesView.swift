import SwiftUI
import RuulUI
import RuulCore

public struct InitialRulesView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var infoRule: RuleDraft?

    public var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Las reglas del grupo",
            subtitle: "Puedes editarlas o agregar más después.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromRules() } }),
            secondaryCTA: ("Mi grupo no usa multas", { Task { await coord.skipRules() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                ForEach(coord.draft.rules.indices, id: \.self) { idx in
                    ruleCard(at: idx)
                }
                rotationSection
                if let errorMessage {
                    Text(errorMessage)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulNegative)
                        .padding(RuulSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .fill(Color.ruulNegative.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .stroke(Color.ruulNegative.opacity(0.4), lineWidth: 1)
                        )
                }
            }
        }
        .ruulSheet(item: $infoRule) { rule in
            ruleInfoSheet(for: rule)
        }
    }

    private var errorMessage: String? {
        guard let err = coord.error, case .createRulesFailed(let msg) = err else { return nil }
        return "No pudimos guardar las reglas: \(msg)"
    }

    private var progressValue: Double {
        Double(FounderStep.rules.index) / Double(FounderStep.allCases.count - 1)
    }

    private func ruleCard(at idx: Int) -> some View {
        let rule = coord.draft.rules[idx]
        return RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                        Text(rule.name)
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text(rule.description)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                    Button { infoRule = rule } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    .buttonStyle(.plain)
                    Toggle("", isOn: Binding(
                        get: { coord.draft.rules[idx].isActive },
                        set: { coord.draft.rules[idx].isActive = $0 }
                    ))
                    .labelsHidden()
                    .tint(Color.ruulAccent)
                }
                if rule.isActive {
                    HStack {
                        Text("Multa")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                        Spacer()
                        TextField("$200", value: Binding(
                            get: { coord.draft.rules[idx].amountMXN },
                            set: { coord.draft.rules[idx].amountMXN = $0 }
                        ), format: .currency(code: "MXN").presentation(.narrow).precision(.fractionLength(0)))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .ruulTextStyle(RuulTypography.title)
                            .foregroundStyle(Color.ruulTextAccent)
                    }
                }
            }
        }
        .opacity(rule.isActive ? 1.0 : 0.55)
        .animation(.ruulSnappy, value: rule.isActive)
    }

    private var rotationSection: some View {
        @Bindable var b = coord
        return VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Tu grupo rota anfitrión?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            RuulSegmentedControl(
                selection: $b.draft.rotationMode,
                segments: RotationMode.allCases.map { ($0, segmentLabel(for: $0)) }
            )
            Text(coord.draft.rotationMode.description)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private func segmentLabel(for mode: RotationMode) -> String {
        switch mode {
        case .autoOrder: return "Sí"
        case .manual:    return "Manual"
        case .noHost:    return "No"
        }
    }

    private func ruleInfoSheet(for rule: RuleDraft) -> some View {
        ModalSheetTemplate(
            title: rule.name,
            primaryCTA: ("Entendido", { infoRule = nil })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                Text(rule.description)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(exampleText(for: rule))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            }
        }
    }

    private func exampleText(for rule: RuleDraft) -> String {
        switch rule.slug {
        case DinnerRecurringTemplate.RuleSlug.lateArrival:
            return "Ejemplo: si llegas a las 9:35 cuando empezaba a las 9:00, " +
                "pagas $\(rule.amountMXN) + $50 = $\(rule.amountMXN + 50)."
        case DinnerRecurringTemplate.RuleSlug.noResponse:
            return "Ejemplo: si la cena es jueves y no confirmas antes del miércoles a las 20:00, " +
                "pagas $\(rule.amountMXN)."
        case DinnerRecurringTemplate.RuleSlug.sameDayCancel:
            return "Ejemplo: si la cena es a las 9 PM y cancelas a las 6 PM del mismo día, " +
                "pagas $\(rule.amountMXN)."
        case DinnerRecurringTemplate.RuleSlug.noShow:
            return "Ejemplo: confirmaste que ibas, no llegaste, no avisaste. " +
                "Pagas $\(rule.amountMXN)."
        case DinnerRecurringTemplate.RuleSlug.hostNoMenu:
            return "Ejemplo: eres el anfitrión y la cena es mañana, pero hoy a las 9 PM " +
                "todavía no avisaste qué se va a comer. Pagas $\(rule.amountMXN)."
        default:
            return "Ejemplo concreto pendiente."
        }
    }
}

