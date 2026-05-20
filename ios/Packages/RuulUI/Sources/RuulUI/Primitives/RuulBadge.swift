import SwiftUI

/// Capsule pill — Luma-style small chrome that surfaces status, meta,
/// or accent metadata. Two axes:
///
/// - **Semantic styles** (`.positive` / `.negative` / `.warning` /
///   `.info` / `.neutral`) — use a tinted background + matching
///   foreground so the pill reads as a status indicator.
/// - **Decorative styles** (`.subtle` / `.accent`) — use a glass /
///   accent fill for meta tags ("Hosteas tú", "Recurrente",
///   "Próximamente"). Replaces the inline `Capsule().fill(Color.ruul
///   FillGlass)` and `Capsule().fill(Color.ruulAccent.opacity(.12))`
///   patterns duplicated across 10+ feature files.
public struct RuulBadge: View {
    public enum Style: Sendable, Hashable {
        case neutral, positive, negative, warning, info
        /// Glass-quiet decorative pill — soft fill, secondary text.
        /// Use for non-status meta tags ("Hosteas tú", "Recurrente").
        case subtle
        /// Accent-tinted decorative pill — ~14% accent fill, accent
        /// text. Use for action / category hints.
        case accent

        var background: Color {
            switch self {
            case .neutral:  return Color.ruulNeutral.opacity(0.15)
            case .positive: return .green.opacity(0.15)
            case .negative: return .red.opacity(0.15)
            case .warning:  return .orange.opacity(0.15)
            case .info:     return .blue.opacity(0.15)
            case .subtle:   return .ruulFillGlass
            case .accent:   return Color.ruulAccent.opacity(RuulOpacity.medium)
            }
        }

        var foreground: Color {
            switch self {
            case .neutral:  return .secondary
            case .positive: return .green
            case .negative: return .red
            case .warning:  return .orange
            case .info:     return .blue
            case .subtle:   return .secondary
            case .accent:   return .ruulAccent
            }
        }
    }

    private let text: String
    private let style: Style
    private let icon: String?

    public init(_ text: String, style: Style = .neutral, icon: String? = nil) {
        self.text = text
        self.style = style
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(style.foreground)
        .background(style.background)
        .clipShape(Capsule())
    }
}

#if DEBUG
#Preview("RuulBadge") {
    VStack(spacing: RuulSpacing.md) {
        HStack {
            RuulBadge("Pendiente", style: .warning, icon: "clock")
            RuulBadge("Confirmado", style: .positive, icon: "checkmark")
            RuulBadge("Multa", style: .negative)
            RuulBadge("Info", style: .info)
            RuulBadge("Neutral")
        }
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
