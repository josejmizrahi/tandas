import SwiftUI
import RuulUI
import RuulCore

/// Onboarding step: rules placeholder.
///
/// Post BigBang, rules are tied to capability blocks on Resources, not to
/// the Group. The founder configures rules later via the ResourceWizard
/// (Phase 2) when creating individual resources. This screen now just
/// describes what's coming and lets the founder continue.
public struct InitialRulesView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    public var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Las reglas vendrán después",
            subtitle: "Cuando crees un evento, gasto, fondo o asset, podrás elegir qué reglas aplican.",
            primaryCTA: ("Continuar", coord.isLoading, { Task { await coord.advanceFromRules() } }),
            secondaryCTA: ("Mi grupo no usa multas", { Task { await coord.skipRules() } }),
            canContinue: true
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                infoCard
                if let errorMessage {
                    Text(errorMessage)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulNegative)
                }
            }
        }
    }

    private var errorMessage: String? {
        guard let err = coord.error, case .createRulesFailed(let msg) = err else { return nil }
        return "No pudimos guardar las reglas: \(msg)"
    }

    private var progressValue: Double {
        Double(FounderStep.rules.index) / Double(FounderStep.allCases.count - 1)
    }

    private var infoCard: some View {
        RuulCard(.tile) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(spacing: RuulSpacing.sm) {
                    RuulIconBadge("list.bullet.clipboard", size: .medium)
                    Text("Cómo funcionarán las reglas")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Text("Las reglas viven en cada recurso (eventos, gastos, fondos, assets). Cuando crees uno, te preguntaremos qué reglas activar y con qué montos. Puedes empezar simple y agregar más después.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }
}
