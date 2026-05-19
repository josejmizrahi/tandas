import SwiftUI
import RuulCore
import RuulUI

/// Layer 1: compact identity ribbon (~56pt). Renders icon + title +
/// one subtitle line composed by dot-joining `subtitleSegments`.
struct IdentityRibbonView: View {
    let ribbon: IdentityRibbon

    var body: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: ribbon.icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(ribbon.tint.color)
                .frame(width: 40, height: 40)
                .background(
                    ribbon.tint.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(ribbon.title)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                if !ribbon.subtitleSegments.isEmpty {
                    Text(ribbon.subtitleSegments.joined(separator: " · "))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
