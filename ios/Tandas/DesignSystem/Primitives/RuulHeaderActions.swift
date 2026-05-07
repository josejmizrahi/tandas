import SwiftUI

/// Container que agrupa N pill buttons en una sola pill compartida.
/// Per DS doc §3.4.
public struct RuulHeaderActions<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        // TODO v3 §13: replace .regularMaterial → .glassBackground() / .glassMaterial()
        //             cuando SwiftUI iOS 26 SDK los exponga.
        .background(Capsule().fill(.regularMaterial))
    }
}

#if DEBUG
#Preview("RuulHeaderActions") {
    HStack {
        RuulPillButton(symbol: "chevron.left") {}
        Spacer()
        RuulHeaderActions {
            RuulPillButton(symbol: "magnifyingglass") {}
            RuulPillButton(symbol: "ellipsis") {}
        }
    }
    .padding(RuulSpacing.md)
    .background(Color.ruulBackground)
}
#endif
