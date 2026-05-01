import SwiftUI

/// Apply iOS 26 Liquid Glass with a ruul-flavored API.
///
/// Wraps `glassEffect(_:in:)` and falls back to a solid material when the
/// user has reduce-transparency enabled.
///
/// - Parameters:
///   - shape: the clip shape that the glass conforms to.
///   - material: thin/regular/thick.
///   - tint: optional accent tint mixed into the glass.
///   - interactive: whether to mark the glass as interactive (subtle press
///     deformation).
public extension View {
    @ViewBuilder
    func ruulGlass<S: InsettableShape>(
        _ shape: S,
        material: GlassMaterial = .regular,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        RuulGlassModifier(content: self, shape: shape, material: material, tint: tint, interactive: interactive)
    }
}

private struct RuulGlassModifier<Content: View, S: InsettableShape>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let content: Content
    let shape: S
    let material: GlassMaterial
    let tint: Color?
    let interactive: Bool

    var body: some View {
        if reduceTransparency {
            content
                .background(Color.ruulBackgroundElevated, in: shape)
                .overlay(shape.strokeBorder(Color.ruulBorderDefault, lineWidth: 0.5))
        } else {
            content.glassEffect(resolvedGlass, in: shape)
        }
    }

    private var resolvedGlass: Glass {
        // iOS 26's `glassEffect(_:in:)` accepts a `Glass` value. The ruul DS
        // currently maps every material onto `.regular` because the SDK only
        // ships one Glass material today; thin/thick are reserved for future
        // SDK additions. Tint and interactivity are applied in either case.
        var base: Glass = .regular
        if let tint {
            base = base.tint(tint)
        }
        if interactive {
            base = base.interactive()
        }
        // material is intentionally unused for now; left in the API so callers
        // don't need to change when the SDK exposes thin/thick variants.
        _ = material
        return base
    }
}
