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

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .solid:
            content
                .background(Color.ruulSurface, in: shapeFor(radius))
        case .glass:
            // 2026-05-15: dropped card chrome entirely — no fill, no
            // shadow, no border. The "contorno gris" complaint and the
            // gray-stamp look come from any card chrome that contrasts
            // against the canvas. Rows now look like Apple Settings /
            // Mail list items: plain content separated by hairline
            // dividers (the parent stack supplies the divider between
            // siblings via `VStack(spacing: 0)` + `Divider()` or the
            // `.ruulSeparatedRows()` helper on RuulUI).
            //
            // `radius` is intentionally unused for `.glass` — list rows
            // are square. Other variants still honor it.
            content
        case .recessed:
            content
                .background(Color.ruulBackgroundRecessed, in: shapeFor(radius))
        }
    }

    private func shapeFor(_ r: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: r, style: .continuous)
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
