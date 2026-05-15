import SwiftUI

/// Full-screen ambient color field derived from a resource's palette.
/// Renders a heavily-blurred mesh gradient layered over the canvas so
/// the underlying view inherits a *hint* of the resource's "mood" —
/// not a saturated stamp.
///
/// Use as the bottom-most layer of a ZStack with `.ignoresSafeArea()`.
/// Pair with translucent surfaces (`.ultraThinMaterial` panels, glass
/// cards) so the ambient bleeds through wherever content doesn't need
/// opaque chrome.
///
/// **2026-05-15 tone-down:** `.soft` (the default, used as global app
/// background) now layers a low-opacity mesh OVER the canvas instead
/// of fading at the bottom. Net effect is mostly-canvas with a quiet
/// palette breath — same idea as Luma where the cover color tints the
/// view but doesn't dominate it.
@MainActor
public struct RuulAmbientBackground: View {
    public let palette: [Color]
    public let style: Style

    public enum Style: Sendable, Hashable {
        /// Quiet palette tint over the canvas. ~25% mesh opacity —
        /// you sense the color, you don't read it as the primary
        /// background. Use as the global app background under every
        /// content surface.
        case soft
        /// Vivid tint — closer to the source palette. ~85% mesh
        /// opacity, with a bottom fade to canvas for text legibility.
        /// Use for hero / cover-adjacent surfaces.
        case vivid

        /// Per-style mesh opacity (over the canvas base layer).
        var meshOpacity: Double {
            switch self {
            case .soft:  return 0.25
            case .vivid: return 0.85
            }
        }

        /// Saturation applied to the blurred mesh before opacity.
        /// Soft drops saturation further so even the visible tint is
        /// muted — Luma feel, not a Trapper Keeper.
        var meshSaturation: Double {
            switch self {
            case .soft:  return 0.65
            case .vivid: return 1.0
            }
        }

        /// `.vivid` also bottom-fades to canvas so on-image text
        /// (cover hero, invite poster) stays legible. `.soft` has no
        /// bottom fade because the mesh is already quiet enough.
        var bottomFadeOpacity: Double {
            switch self {
            case .soft:  return 0.0
            case .vivid: return 0.25
            }
        }
    }

    public init(palette: [Color], style: Style = .soft) {
        self.palette = palette
        self.style = style
    }

    public var body: some View {
        ZStack {
            // Canvas base layer — every variant starts from system
            // background; the mesh layers on top at the configured
            // opacity. Keeps light/dark mode consistent (the canvas
            // token adapts).
            Color.ruulBackgroundCanvas
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
            .blur(radius: RuulSize.blurAmbient)
            .saturation(style.meshSaturation)
            .opacity(style.meshOpacity)
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
#Preview("RuulAmbientBackground — soft sunset") {
    let sunset: [Color] = [
        Color(red: 1.00, green: 0.69, blue: 0.60),
        Color(red: 1.00, green: 0.44, blue: 0.57),
        Color(red: 0.78, green: 0.38, blue: 1.00)
    ]
    return ZStack {
        RuulAmbientBackground(palette: sunset)
        VStack(spacing: RuulSpacing.lg) {
            Text("Quiet ambient")
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Glass cards still pick up the tint")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(RuulSpacing.lg)
    }
}

#Preview("RuulAmbientBackground — vivid ocean") {
    let ocean: [Color] = [
        Color(red: 0.18, green: 0.83, blue: 0.75),
        Color(red: 0.02, green: 0.71, blue: 0.83),
        Color(red: 0.23, green: 0.51, blue: 0.96)
    ]
    return RuulAmbientBackground(palette: ocean, style: .vivid)
}
#endif
