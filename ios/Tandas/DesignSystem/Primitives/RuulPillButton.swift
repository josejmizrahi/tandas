import SwiftUI

/// Pill icon button con `.regularMaterial`. Usado para back nav y header
/// actions. Per DS doc §3.3.
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
    private let action: () -> Void

    @State private var triggerCount = 0

    public init(symbol: String, size: Size = .regular, action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button {
            triggerCount &+= 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size.symbolSize, weight: .medium))
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(width: size.dimension, height: size.dimension)
                // TODO v3 §13: replace .regularMaterial → .glassBackground() / .glassMaterial()
                //             cuando SwiftUI iOS 26 SDK los exponga.
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .ruulHaptic(.light, trigger: triggerCount)
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
