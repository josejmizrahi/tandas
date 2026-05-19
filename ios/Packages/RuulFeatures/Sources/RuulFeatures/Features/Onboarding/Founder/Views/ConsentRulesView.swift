import SwiftUI
import RuulUI
import RuulCore

/// Beta 1 W3 B-3.4 — consent step shown after preset selection and before
/// invite. Surfaces the rules the template just seeded so the first-time
/// user sees what's behind the curtain *before* anyone is in the group.
///
/// Backbone: B-1.1 (`isActive=false` on monetary fines from the dinner
/// template). The rules listed here are not enforcing anything yet — the
/// copy makes that explicit ("Por ahora están en modo sugerencia"). The
/// founder turns them on from the Rules tab when the group is ready.
///
/// Driven entirely by `FounderOnboardingCoordinator.templateRulePreviews`.
/// No vertical hardcoding — whatever rules `seedTemplateRules` returns
/// for the chosen template show up here. "Empezar de cero" (no template)
/// skips this step entirely (coordinator routes preset → invite directly).
public struct ConsentRulesView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    public init() {}

    public var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: FounderStep.consent.progressFraction,
            stepCount: FounderStep.visibleSteps.count,
            title: "Reglas sugeridas",
            subtitle: "Estas son las reglas que la gente suele usar. Por ahora están en modo sugerencia — no se activan hasta que tu grupo decida.",
            primaryCTA: ("Continuar", false, { Task { await coord.advanceFromConsent() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                ForEach(coord.templateRulePreviews) { rule in
                    ruleRow(rule)
                }
                footnote
                    .padding(.top, RuulSpacing.sm)
            }
        }
    }

    private func ruleRow(_ rule: OnboardingRule) -> some View {
        HStack(alignment: .center, spacing: RuulSpacing.md) {
            RuulIconBadge("doc.text", size: .medium)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(rule.name)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("En modo sugerencia")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: RuulSpacing.xs) {
            Image(systemName: "info.circle")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text("Podrás revisar y activar cada regla desde la sección Reglas cuando estén todos listos.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer(minLength: 0)
        }
    }
}
