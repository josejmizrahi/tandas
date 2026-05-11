import SwiftUI
import RuulUI

/// Placeholder sheet for event-scoped capability surfaces that don't yet
/// have a creation flow (rules-in-event, ledger entries, etc). Shows
/// what's coming and which phase it ships in. Replace with the real
/// creation sheet as each capability lands.
struct EventCapabilityPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let icon: String
    let title: String
    let summary: String
    let comingFromPhase: String

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xl) {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.ruulAccent.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.ruulAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Próximamente")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Text(summary)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(comingFromPhase)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.sm)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            Spacer()
            RuulButton("Entendido", style: .primary, size: .large, fillsWidth: true) {
                dismiss()
            }
        }
        .padding(RuulSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackground.ignoresSafeArea())
    }
}
