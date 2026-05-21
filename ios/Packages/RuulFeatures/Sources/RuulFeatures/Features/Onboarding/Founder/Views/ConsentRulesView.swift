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
            progress: FounderStep.consent.progressFraction,
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
            Image(systemName: "doc.text")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(rule.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text("En modo sugerencia")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: RuulSpacing.xs) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text("Podrás revisar y activar cada regla desde la sección Reglas cuando estén todos listos.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 0)
        }
    }
}
