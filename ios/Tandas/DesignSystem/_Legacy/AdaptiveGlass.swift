import SwiftUI

extension View {
    @ViewBuilder
    func adaptiveGlass<S: InsettableShape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        ModifierBody(content: self, shape: shape, tint: tint, interactive: interactive)
    }
}

private struct ModifierBody<Content: View, S: InsettableShape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content: Content
    let shape: S
    let tint: Color?
    let interactive: Bool

    var body: some View {
        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        } else {
            // iOS 26 Liquid Glass: `glassEffect(_:in:)` accepts a `Glass` value.
            // The plan referenced a `GlassEffect` type with `.regular`, `.tinted(_:)`,
            // and `.interactive()`; the actual SDK type is `Glass` with the same
            // surface — adjust to whatever compiles in iOS 26.4 SDK.
            let style: Glass = {
                let base: Glass = tint.map { .regular.tint($0) } ?? .regular
                return interactive ? base.interactive() : base
            }()
            content.glassEffect(style, in: shape)
        }
    }
}
