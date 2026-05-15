import SwiftUI

/// Full-screen ambient color field derived from a resource's palette.
/// Renders a heavily-blurred mesh gradient so the underlying view
/// inherits the resource's "mood" the way Luma tints every event
/// detail with its cover's dominant colors.
///
/// Use as the bottom-most layer of a ZStack with `.ignoresSafeArea()`.
/// Pair with translucent surfaces (`.ultraThinMaterial` panels, glass
/// cards) so the ambient bleeds through wherever content doesn't need
/// opaque chrome.
@MainActor
public struct RuulAmbientBackground: View {
    public let palette: [Color]
    public let style: Style

    public enum Style: Sendable, Hashable {
        /// Soft palette tint — keep underlying canvas color readable
        /// alongside the ambient mood. Used as the global app
        /// background under content surfaces.
        case soft
        /// Vivid tint — closer to the source palette, less dimmed.
        /// Used for hero / cover-adjacent surfaces.
        case vivid
    }

    public init(palette: [Color], style: Style = .soft) {
        self.palette = palette
        self.style = style
    }

    public var body: some View {
        ZStack {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    .init(0, 0), .init(0.5, 0), .init(1, 0),
                    .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                    .init(0, 1), .init(0.5, 1), .init(1, 1)
                ],
                colors: paddedPalette
            )
            .blur(radius: 80)
            .saturation(style == .soft ? 0.85 : 1.0)
            // Bottom fade to recessed canvas so foreground text stays
            // legible without flattening the overall tint. The fade
            // sits on top of the blurred mesh so the bottom 30% of
            // the screen converges toward the canvas color.
            LinearGradient(
                colors: [
                    Color.ruulBackgroundCanvas.opacity(0),
                    Color.ruulBackgroundCanvas.opacity(style == .soft ? 0.55 : 0.25)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    /// MeshGradient with 3×3=9 stops needs 9 colors. Tile the supplied
    /// palette if shorter; truncate if longer. Tiling repeats colors
    /// across the mesh which the heavy blur smooths into a continuous
    /// field — no visible banding.
    private var paddedPalette: [Color] {
        guard !palette.isEmpty else {
            return Array(repeating: Color.ruulBackgroundCanvas, count: 9)
        }
        if palette.count >= 9 { return Array(palette.prefix(9)) }
        var out = palette
        while out.count < 9 {
            out.append(palette[out.count % palette.count])
        }
        return out
    }
}

#if DEBUG
#Preview("RuulAmbientBackground — sunset palette") {
    let sunset: [Color] = [
        Color(red: 1.00, green: 0.69, blue: 0.60),
        Color(red: 1.00, green: 0.44, blue: 0.57),
        Color(red: 0.78, green: 0.38, blue: 1.00),
        Color(red: 1.00, green: 0.63, blue: 0.50),
        Color(red: 1.00, green: 0.44, blue: 0.57),
        Color(red: 0.63, green: 0.48, blue: 1.00),
        Color(red: 1.00, green: 0.82, blue: 0.48),
        Color(red: 0.90, green: 0.36, blue: 0.69),
        Color(red: 0.48, green: 0.36, blue: 1.00)
    ]
    return ZStack {
        RuulAmbientBackground(palette: sunset)
        VStack(spacing: RuulSpacing.lg) {
            Text("Hero title")
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(.white)
            Text("Glass surfaces pick up the ambient tint")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(RuulSpacing.lg)
    }
}

#Preview("RuulAmbientBackground — vivid") {
    let ocean: [Color] = [
        Color(red: 0.18, green: 0.83, blue: 0.75),
        Color(red: 0.02, green: 0.71, blue: 0.83),
        Color(red: 0.23, green: 0.51, blue: 0.96)
    ]
    return RuulAmbientBackground(palette: ocean, style: .vivid)
}
#endif
