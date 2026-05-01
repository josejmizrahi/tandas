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
            .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous), tint: tint, interactive: interactive)
    }
}
