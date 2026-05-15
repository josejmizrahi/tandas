import SwiftUI

/// Canonical card-body surface treatments. Every screen-level card in
/// Ruul (list rows, dashboard tiles, sheet rows, detail sections) goes
/// through one of these three styles via `.ruulCardSurface(_:)` — never
/// hand-rolled `.background(...)` chrome.
///
/// Decision tree:
/// - The parent screen renders an ambient palette layer → use `.glass`
///   so the card picks up the tint instead of cutting it off.
/// - The card sits on the system canvas without an ambient → use
///   `.solid` for a clean elevated surface.
/// - The card is a quiet detail inside another card (a row that should
///   recede further) → use `.recessed`.
public enum RuulSurfaceStyle: Sendable, Hashable {
    case solid
    case glass
    case recessed
}

public extension View {
    /// Apply the canonical Ruul card surface — fill, radius, elevation,
    /// all in one place. Replaces ad-hoc inline patterns like
    /// `.background(Color.ruulSurface, in: RoundedRectangle(...))`.
    func ruulCardSurface(
        _ style: RuulSurfaceStyle = .glass,
        radius: CGFloat = RuulRadius.large
    ) -> some View {
        modifier(RuulCardSurfaceModifier(style: style, radius: radius))
    }
}

private struct RuulCardSurfaceModifier: ViewModifier {
    let style: RuulSurfaceStyle
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .solid:
            content
                .background(Color.ruulSurface, in: shape)
                .ruulElevation(.sm)
        case .glass:
            // 2026-05-15: dropped `.ultraThinMaterial` because on the
            // warm-cream canvas it rendered as a visibly LIGHTER frost
            // — cards read as "stamps with a gray contorno" instead of
            // "lifted glass". The material needs ambient color behind
            // it to refract; on a flat canvas there's nothing to grab.
            //
            // The new glass card is canvas-colored fill + soft drop
            // shadow. On canvas screens the fill matches the bg so the
            // edge is invisible — only the shadow telegraphs lift. On
            // ambient surfaces (event detail) the canvas-colored fill
            // sits a step away from the tinted bg so the card reads as
            // "a piece of canvas raised up", still quiet but defined.
            content
                .background(Color.ruulBackgroundCanvas, in: shape)
                .ruulElevation(.sm)
        case .recessed:
            content
                .background(Color.ruulBackgroundRecessed, in: shape)
        }
    }
}

#if DEBUG
#Preview("ruulCardSurface") {
    VStack(spacing: RuulSpacing.md) {
        Text("Solid — opaque elevated")
            .padding(RuulSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ruulCardSurface(.solid)
        Text("Glass — picks up ambient tint")
            .padding(RuulSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ruulCardSurface(.glass)
        Text("Recessed — quiet inner row")
            .padding(RuulSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ruulCardSurface(.recessed)
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
