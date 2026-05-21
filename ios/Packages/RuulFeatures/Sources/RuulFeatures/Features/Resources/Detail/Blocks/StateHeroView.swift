import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Identity layer hero**.
///
/// The single answer-block for "¿Qué está pasando ahora?" + "¿Qué
/// puedo hacer?". Above the fold below the identity ribbon. Apple
/// Calendar / Wallet / Reminders all put the most load-bearing
/// current-state line at title weight so the eye lands here first.
///
/// Doctrine (`Plans/Active/Fase1ComponentMap.md` §"Universal Resource
/// Detail — Identity layer"): the viewer's relationship to the
/// resource ("Eres anfitrión", "Aportaste $500 este mes", "Mañana
/// 8:00 PM") shows below the ribbon as a strong anchor — NOT in a
/// separate "you" block.
///
/// Inline primary action sits at the bottom edge of the same block —
/// no floating CTA, no sticky footer. Calm doctrine.
struct StateHeroView: View {
    let headline: StateHeadline
    let tint: ResourceFamilyTint
    let onPrimaryTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text(headline.headline)
                .font(.title.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(3)
            if !headline.supportingFacts.isEmpty {
                Text(headline.supportingFacts.joined(separator: " · "))
                    .font(.body)
                    .foregroundStyle(Color.secondary)
            }
            if let action = headline.primaryAction, action.kind != .none {
                Button(action: onPrimaryTap) {
                    HStack {
                        if let symbol = action.symbol {
                            Image(systemName: symbol)
                        }
                        Text(action.label)
                            .font(.body.weight(.semibold))
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
