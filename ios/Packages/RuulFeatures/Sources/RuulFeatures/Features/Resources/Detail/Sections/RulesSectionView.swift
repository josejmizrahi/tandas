import SwiftUI
import RuulUI
import RuulCore

/// Rules primitive renderer. Mirrors MoneySectionView shape — tap →
/// caller presents `ResourceRulesSheet`. The sheet handles add /
/// edit / propose-change UX (governance plan from feat/group-
/// governance-policies wires resolve_governance into the save path).
public struct RulesSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "rules",
        priority: 800,
        isEnabledFor: { caps in caps.contains("rules") },
        render: { ctx in AnyView(RulesSectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader("ACUERDOS")
            Button(action: context.onPresentRules) {
                HStack(spacing: RuulSpacing.sm) {
                    iconBadge(systemName: "list.bullet.clipboard.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reglas de este recurso")
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Lo que se cumple sin pensar — multas, límites, votos.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(RuulSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardBackground()
        }
    }

    private func iconBadge(systemName: String) -> some View {
        ZStack {
            Circle().fill(Color.ruulAccent.opacity(0.15)).frame(width: 36, height: 36)
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ruulAccent)
        }
    }
}
