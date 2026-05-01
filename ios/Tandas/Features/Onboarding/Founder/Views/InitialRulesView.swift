import SwiftUI

struct InitialRulesView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var infoRule: RuleDraft?

    var body: some View {
        @Bindable var bindable = coord
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
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                ForEach(coord.draft.rules.indices, id: \.self) { idx in
                    ruleCard(at: idx, bindable: bindable)
                }
                rotationSection(bindable: bindable)
            }
        }
        .ruulSheet(item: $infoRule) { rule in
            ruleInfoSheet(for: rule)
        }
    }

    private var progressValue: Double {
        Double(FounderStep.rules.index) / Double(FounderStep.allCases.count - 1)
    }

    private func ruleCard(at idx: Int, bindable: Bindable<FounderOnboardingCoordinator>) -> some View {
        let rule = coord.draft.rules[idx]
        return RuulCard(.glass) {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.title)
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
                        get: { coord.draft.rules[idx].enabled },
                        set: { coord.draft.rules[idx].enabled = $0 }
                    ))
                    .labelsHidden()
                    .tint(Color.ruulAccentPrimary)
                }
                if rule.enabled {
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
        .opacity(rule.enabled ? 1.0 : 0.55)
        .animation(.ruulSnappy, value: rule.enabled)
    }

    private func rotationSection(bindable: Bindable<FounderOnboardingCoordinator>) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("¿Tu grupo rota anfitrión?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            RuulSegmentedControl(
                selection: $bindable.draft.rotationMode,
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
            title: rule.title,
            primaryCTA: ("Entendido", { infoRule = nil })
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                Text(rule.description)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(exampleText(for: rule))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.md))
            }
        }
    }

    private func exampleText(for rule: RuleDraft) -> String {
        switch rule.code {
        case "late":
            return "Ejemplo: si llegas a las 9:35 cuando empezaba a las 9:00, " +
                "pagas $\(rule.amountMXN) + $50 = $\(rule.amountMXN + 50)."
        case "no_rsvp":
            return "Ejemplo: si la cena es jueves y no confirmas antes del miércoles a las 20:00, " +
                "pagas $\(rule.amountMXN)."
        case "cancel_same_day":
            return "Ejemplo: si la cena es a las 9 PM y cancelas a las 6 PM del mismo día, " +
                "pagas $\(rule.amountMXN)."
        case "no_show":
            return "Ejemplo: confirmaste que ibas, no llegaste, no avisaste. " +
                "Pagas $\(rule.amountMXN)."
        case "host_no_menu":
            return "Ejemplo: eres el anfitrión y la cena es mañana, pero hoy a las 9 PM " +
                "todavía no avisaste qué se va a comer. Pagas $\(rule.amountMXN)."
        default:
            return "Ejemplo concreto pendiente."
        }
    }
}

