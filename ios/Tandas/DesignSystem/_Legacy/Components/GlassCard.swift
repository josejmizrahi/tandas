import SwiftUI

struct GlassCard<Content: View>: View {
    let tint: Color?
    let interactive: Bool
    let content: () -> Content

    init(tint: Color? = nil, interactive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.interactive = interactive
        self.content = content
    }

    var body: some View {
        content()
            .padding(Brand.Spacing.l)
            .lumaCard()
    }
}

// Luma-style modifier: flat dark surface + 1px subtle white border, no glass blur.
extension View {
    func lumaCard(cornerRadius: CGFloat = Brand.Radius.card) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Brand.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.Surface.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
