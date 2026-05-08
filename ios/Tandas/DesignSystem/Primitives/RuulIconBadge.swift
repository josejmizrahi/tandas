import SwiftUI
import RuulUI

/// Glass container with an SF Symbol inside, color tint configurable.
public struct RuulIconBadge: View {
    public enum Size: Sendable, Hashable {
        case small, medium, large

        var diameter: CGFloat {
            switch self {
            case .small:  return 32
            case .medium: return 44
            case .large:  return 56
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .small:  return 14
            case .medium: return 20
            case .large:  return 26
            }
        }
    }

    private let systemImage: String
    private let tint: Color
    private let size: Size

    public init(_ systemImage: String, tint: Color = .ruulAccent, size: Size = .medium) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size.iconSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size.diameter, height: size.diameter)
            .ruulGlass(Circle(), material: .regular, tint: tint.opacity(0.15))
    }
}

#if DEBUG
#Preview("RuulIconBadge") {
    HStack(spacing: RuulSpacing.md) {
        VStack(spacing: RuulSpacing.sm) {
            RuulIconBadge("calendar", size: .small)
            RuulIconBadge("calendar", size: .medium)
            RuulIconBadge("calendar", size: .large)
        }
        VStack(spacing: RuulSpacing.sm) {
            RuulIconBadge("checkmark", tint: .ruulPositive)
            RuulIconBadge("exclamationmark.triangle", tint: .ruulWarning)
            RuulIconBadge("xmark", tint: .ruulNegative)
        }
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
