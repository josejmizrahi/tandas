import SwiftUI
import RuulUI

/// Badge cápsula tinted para estados. Per DS doc §3.10.
/// Coexiste con RuulChip por ahora — Fase D consolida si aplica.
public struct RuulBadge: View {
    public enum Style: Sendable, Hashable {
        case neutral, positive, negative, warning, info

        var background: Color {
            switch self {
            case .neutral:  return Color.ruulNeutral.opacity(0.15)
            case .positive: return .ruulPositiveBackground
            case .negative: return .ruulNegativeBackground
            case .warning:  return .ruulWarningBackground
            case .info:     return .ruulInfoBackground
            }
        }

        var foreground: Color {
            switch self {
            case .neutral:  return .ruulTextSecondary
            case .positive: return .ruulPositive
            case .negative: return .ruulNegative
            case .warning:  return .ruulWarning
            case .info:     return .ruulInfo
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
                .font(.ruulMicro.weight(.semibold))
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
