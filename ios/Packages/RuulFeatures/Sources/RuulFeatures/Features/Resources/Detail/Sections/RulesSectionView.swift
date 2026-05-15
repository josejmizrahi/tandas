import SwiftUI
import RuulUI
import RuulCore

/// Rules primitive renderer. Settings-style single-row entry that opens
/// `ResourceRulesSheet` for the resource. The sheet handles add / edit /
/// propose-change UX (governance plan from feat/group-governance-policies
/// wires `resolve_governance` into the save path).
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
            Text("Reglas")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
                .padding(.horizontal, RuulSpacing.xxs)

            Button(action: context.onPresentRules) {
                HStack(spacing: RuulSpacing.md) {
                    Image(systemName: "list.bullet.clipboard.fill")
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                        .foregroundStyle(Color.ruulAccent)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reglas de este recurso")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Lo que se cumple sin pensar.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .ruulTextStyle(RuulTypography.labelSmSemibold)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, RuulSpacing.md)
                .padding(.vertical, RuulSpacing.md)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            )
            .accessibilityLabel("Ver reglas del recurso")
        }
    }
}
