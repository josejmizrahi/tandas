import SwiftUI

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

    public init(_ systemImage: String, tint: Color = .ruulAccentPrimary, size: Size = .medium) {
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
    HStack(spacing: RuulSpacing.s4) {
        VStack(spacing: RuulSpacing.s3) {
            RuulIconBadge("calendar", size: .small)
            RuulIconBadge("calendar", size: .medium)
            RuulIconBadge("calendar", size: .large)
        }
        VStack(spacing: RuulSpacing.s3) {
            RuulIconBadge("checkmark", tint: .ruulSemanticSuccess)
            RuulIconBadge("exclamationmark.triangle", tint: .ruulSemanticWarning)
            RuulIconBadge("xmark", tint: .ruulSemanticError)
        }
    }
    .padding(RuulSpacing.s5)
    .background(Color.ruulBackgroundCanvas)
}
#endif
