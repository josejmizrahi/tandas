import SwiftUI

/// Full-screen ambient color field — a Luma-style solid color tint
/// over the canvas, NOT a multi-stop mesh gradient. The caller passes
/// a palette (typically derived from a resource's cover or a group's
/// deterministic catalog cover) and the receiver picks a single
/// representative color to lay over the canvas.
///
/// Use as the bottom-most layer of a ZStack with `.ignoresSafeArea()`.
/// Pair with translucent surfaces (`.ultraThinMaterial` panels, glass
/// cards) so the ambient bleeds through wherever content doesn't need
/// opaque chrome.
///
/// **2026-05-15 (option A):** dropped the multi-color MeshGradient in
/// favor of a single-color overlay. Luma's identity pages (Ledger
/// Leaders green, etc.) are uniform tints — not vibrant aurora meshes.
/// The mesh-driven look was closer to Apple Invites / Tripsy than to
/// Luma, which is where the user steered us.
@MainActor
public struct RuulAmbientBackground: View {
    public let palette: [Color]
    public let style: Style

    public enum Style: Sendable, Hashable {
        /// Quiet tint over the canvas — ~18% opacity. Use as the
        /// global app background under content surfaces (sheets,
        /// group-scoped tabs, identity surfaces).
        case soft
        /// Stronger tint — ~45% opacity, with a bottom fade to canvas
        /// for text legibility under on-image content. Use for hero /
        /// cover-adjacent surfaces (resource detail, invite poster).
        case vivid

        /// Tint opacity over the canvas base. Solid color, no gradient.
        var tintOpacity: Double {
            switch self {
            case .soft:  return 0.18
            case .vivid: return 0.45
            }
        }

        /// Bottom-fade opacity that converges back to canvas at the
        /// bottom edge so foreground / sticky CTA text stays legible.
        /// `.soft` doesn't need it because the tint is already quiet.
        var bottomFadeOpacity: Double {
            switch self {
            case .soft:  return 0.0
            case .vivid: return 0.30
            }
        }
    }

    public init(palette: [Color], style: Style = .soft) {
        self.palette = palette
        self.style = style
    }

    public var body: some View {
        ZStack {
            // Canvas always sits at the bottom — every variant
            // starts from system background.
            Color.ruulBackgroundCanvas
            // Single representative color over the canvas at the
            // style's opacity. No mesh, no gradient — Luma uniform
            // tint pattern.
            representativeColor
                .opacity(style.tintOpacity)
            if style.bottomFadeOpacity > 0 {
                LinearGradient(
                    colors: [
                        Color.ruulBackgroundCanvas.opacity(0),
                        Color.ruulBackgroundCanvas.opacity(style.bottomFadeOpacity)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    /// Pick a representative tint from the supplied palette. Index 1
    /// is usually the first vivid stop in `RuulCoverCatalog` palettes
    /// (index 0 is the "background" stop which is muted by design).
    /// Falls back through the palette and finally to canvas when the
    /// caller passes an empty array.
    private var representativeColor: Color {
        guard !palette.isEmpty else { return Color.ruulBackgroundCanvas }
        if palette.count >= 2 { return palette[1] }
        return palette[0]
    }
}

#if DEBUG
#Preview("RuulAmbientBackground — soft sunset") {
    let sunset: [Color] = [
        Color(red: 1.00, green: 0.69, blue: 0.60),
        Color(red: 1.00, green: 0.44, blue: 0.57),
        Color(red: 0.78, green: 0.38, blue: 1.00)
    ]
    return ZStack {
        RuulAmbientBackground(palette: sunset)
        VStack(spacing: RuulSpacing.lg) {
            Text("Quiet ambient tint")
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Single color, no mesh — Luma uniform fill")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(RuulSpacing.lg)
    }
}

#Preview("RuulAmbientBackground — vivid ocean") {
    let ocean: [Color] = [
        Color(red: 0.18, green: 0.83, blue: 0.75),
        Color(red: 0.02, green: 0.71, blue: 0.83)
    ]
    return RuulAmbientBackground(palette: ocean, style: .vivid)
}
#endif
