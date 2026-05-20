import SwiftUI
import RuulCore
import RuulUI

/// Layer 2: the single hero block. Headline + supporting line + inline
/// primary action. NO floating CTA, NO sticky footer — the action is
/// the bottom edge of this block when present.
struct StateHeroView: View {
    let headline: StateHeadline
    let tint: ResourceFamilyTint
    let onPrimaryTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text(headline.headline)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(3)
            if !headline.supportingFacts.isEmpty {
                Text(headline.supportingFacts.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
            if let action = headline.primaryAction, action.kind != .none {
                Button(action: onPrimaryTap) {
                    HStack {
                        if let symbol = action.symbol {
                            Image(systemName: symbol)
                        }
                        Text(action.label)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.style == .destructive ? .red : tint.color)
            }
        }
        .padding(RuulSpacing.lg)
        .background(
            urgencyBackground,
            in: RoundedRectangle(cornerRadius: RuulRadius.lg)
        )
    }

    private var urgencyBackground: AnyShapeStyle {
        switch headline.urgency {
        case .urgent:    return AnyShapeStyle(Color.red.opacity(0.06))
        case .actionable: return AnyShapeStyle(tint.color.opacity(0.06))
        case .ambient, .terminal: return AnyShapeStyle(Color.ruulSurfaceSecondary)
        }
    }
}
