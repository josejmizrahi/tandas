import SwiftUI

// MARK: - Static color accessors
//
// Bridge from legacy `Color.ruul*` names to native system colors. New code
// should prefer `Color(.systemBackground)` / `.primary` / `.accentColor`
// directly; these aliases exist because ~400 call-sites still use them and
// the migration runs gradually.

public extension Color {

    // Backgrounds — translucent card fill (founder pick 2026-05-25 v5).
    //
    // Card fill is `.tertiarySystemFill` — a translucent gray (~12% in
    // light mode, ~24% in dark) that blends with the canvas underneath
    // instead of being an opaque elevated rectangle. The card reads as
    // a quiet patch carved INTO the canvas, not a tile floating above
    // it. Used by iOS 26 controls (segmented controls, search bars,
    // capsule chips) for the same "asentado en el lienzo" feel.
    //
    // Canvas stays `.systemGroupedBackground` (light gray) so the
    // translucent card blends to slightly darker than canvas in light
    // mode and slightly lighter in dark mode — adaptive recessed look.
    static var ruulBackgroundCanvas: Color   { Color(.systemBackground) }
    static var ruulBackgroundElevated: Color { Color(.tertiarySystemFill) }
    static var ruulBackgroundRecessed: Color { Color(.systemGroupedBackground) }

    // Glass-tint fills. Apple's recipe is `.glassEffect()` over content; these
    // bridge to a tertiary system fill while the migration to `.glassEffect()`
    // runs.
    static var ruulSurfaceGlassThin: Color    { Color(.tertiarySystemFill) }
    static var ruulSurfaceGlassRegular: Color { Color(.tertiarySystemFill) }
    static var ruulSurfaceGlassThick: Color   { Color(.tertiarySystemFill) }

    // Text — bridges to the system label hierarchy (adapts to dark + HC).
    static var ruulTextPrimary: Color   { Color(.label) }
    static var ruulTextSecondary: Color { Color(.secondaryLabel) }
    static var ruulTextTertiary: Color  { Color(.tertiaryLabel) }
    /// White over a tinted button label. Bridged to `Color.white`.
    static var ruulTextInverse: Color   { .white }
    /// Foreground for accent-tinted text. Bridged to `Color.accentColor`.
    static var ruulTextAccent: Color    { .accentColor }

    // Accent — single source of truth is the app's Asset Catalog AccentColor.
    static var ruulAccentPrimary: Color   { .accentColor }
    static var ruulAccentSecondary: Color { .secondary }
    static var ruulAccentSubtle: Color    { Color.accentColor.opacity(0.15) }

    // Semantic — bridges to system semantic colors (adapt natively).
    static var ruulSemanticSuccess: Color { Color(.systemGreen) }
    static var ruulSemanticWarning: Color { Color(.systemOrange) }
    static var ruulSemanticError: Color   { Color(.systemRed) }
    static var ruulSemanticInfo: Color    { Color(.systemBlue) }

    // Borders — all bridge to `.separator`. Apple uses materials + separators
    // for visual grouping. Where contrast really matters, the canonical
    // pattern is moving content into a `Section` inside a `List` (which gets
    // separators for free).
    static var ruulBorderSubtle: Color  { Color(.separator) }
    static var ruulBorderDefault: Color { Color(.separator) }
    static var ruulBorderStrong: Color  { Color(.separator) }
    static var ruulBorderGlass: Color   { Color(.separator) }

    /// Modal scrim. Stronger in light mode (so the dim is visible) vs dark.
    static var ruulOverlayDim: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.0, alpha: 0.55)
                : UIColor(white: 0.0, alpha: 0.35)
        })
    }

    /// Soft inner glow for textured surfaces.
    static var ruulOverlayHighlight: Color {
        Color(uiColor: UIColor { trait in
            UIColor(white: 1.0, alpha: trait.userInterfaceStyle == .dark ? 0.10 : 0.18)
        })
    }

    // MARK: - On-image content (always white/translucent, no scheme adapt)
    //
    // These read against a saturated image backdrop, so they don't adapt to
    // scheme. Use these instead of bare `Color.white` when overlaying text or
    // badges on photos.

    /// Primary text over image/cover.
    static var ruulOnImage: Color          { Color(uiColor: UIColor(white: 1.0, alpha: 1.0)) }
    /// Secondary text over image/cover.
    static var ruulOnImageSecondary: Color { Color(uiColor: UIColor(white: 1.0, alpha: 0.85)) }
    /// Translucent black badge over an image.
    static var ruulImageBadge: Color       { Color(uiColor: UIColor(white: 0.0, alpha: 0.55)) }
    /// Translucent white pill over an image.
    static var ruulImagePill: Color        { Color(uiColor: UIColor(white: 1.0, alpha: 0.22)) }
    /// Translucent white border for pills over images.
    static var ruulImagePillBorder: Color  { Color(uiColor: UIColor(white: 1.0, alpha: 0.30)) }
    /// Solid white pill over an image (high-contrast affordance).
    static var ruulImagePillSolid: Color   { Color(uiColor: .white) }
    /// Vignette gradient mid-stop.
    static var ruulImageVignetteMid: Color  { Color(uiColor: UIColor(white: 0.0, alpha: 0.20)) }
    /// Vignette gradient bottom-stop.
    static var ruulImageVignetteDeep: Color { Color(uiColor: UIColor(white: 0.0, alpha: 0.78)) }
    /// Drop shadow under text on images.
    static var ruulImageTextShadow: Color   { Color(uiColor: UIColor(white: 0.0, alpha: 0.18)) }
    /// Camera viewfinder background.
    static var ruulCameraBackground: Color  { Color(uiColor: .black) }
    /// Text colored to contrast a solid white pill over an image.
    static var ruulOnImageInverse: Color    { Color(uiColor: .black) }

    // MARK: - Glass-quiet fills (input pattern)
    //
    // Theme-adaptive soft fill that reads as "barely-there" against any
    // underlying surface — almost invisible over a glass sheet, just enough
    // shape on a solid background. Used for input fields and soft chips that
    // should pick up the ambient/material tint of their parent.

    /// Rest-state fill for inputs / soft chips. 6% primary-text tint.
    static var ruulFillGlass: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.06)
                : UIColor(white: 0.0, alpha: 0.06)
        })
    }

    /// Hover / pressed / selected variant.
    static var ruulFillGlassStrong: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.12)
                : UIColor(white: 0.0, alpha: 0.10)
        })
    }
}

// MARK: - Hex helper
//
// Used by `RuulCoverCatalog` to encode the cover gradient palette and by
// `GroupColorRamp` for the per-group accent ramps. Not for use in feature
// views — see Lefthook `no-hex-colors` guard.

public extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
