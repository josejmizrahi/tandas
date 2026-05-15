import SwiftUI

/// Pill icon button con Liquid Glass (`.ruulGlass`). Usado para back nav y
/// header actions. Per DS doc §3.3.
public struct RuulPillButton: View {
    public enum Size: Sendable, Hashable {
        case small, regular, large

        var dimension: CGFloat {
            switch self {
            case .small:   return 32
            case .regular: return 40
            case .large:   return 48
            }
        }
        var symbolSize: CGFloat {
            switch self {
            case .small:   return 14
            case .regular: return 18
            case .large:   return 22
            }
        }
    }

    private let symbol: String
    private let size: Size
    private let accessibilityLabel: String?
    private let action: () -> Void

    @State private var triggerCount = 0

    public init(
        symbol: String,
        size: Size = .regular,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button {
            triggerCount &+= 1
            action()
        } label: {
            ZStack {
                // Tap target ≥44pt (HIG), independent of visual size. iOS 26's
                // `glassEffect(_:in:)` with `interactive: true` was observed
                // to swallow taps inside circles smaller than 44pt — the
                // press deformation stole the touch before the Button fired.
                // Solution: outer transparent shape provides a stable 44pt
                // hit area; the visual circle stays at the requested size and
                // is marked `allowsHitTesting(false)` so it never intercepts.
                Circle()
                    .fill(.clear)
                    .frame(
                        width: max(size.dimension, 44),
                        height: max(size.dimension, 44)
                    )
                    .contentShape(Circle())
                Image(systemName: symbol)
                    .font(.system(size: size.symbolSize, weight: .medium))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .frame(width: size.dimension, height: size.dimension)
                    .ruulGlass(Circle(), material: .regular)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .ruulHaptic(.light, trigger: triggerCount)
        .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    }
}

private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(Text(label))
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("RuulPillButton") {
    HStack(spacing: RuulSpacing.sm) {
        RuulPillButton(symbol: "chevron.left", size: .small) {}
        RuulPillButton(symbol: "magnifyingglass") {}
        RuulPillButton(symbol: "ellipsis", size: .large) {}
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
