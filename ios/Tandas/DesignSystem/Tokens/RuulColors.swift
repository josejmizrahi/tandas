import SwiftUI

/// Color tokens for the ruul design system.
///
/// All tokens resolve dynamically via `Color(uiColor: UIColor { trait in ... })`
/// against the runtime `userInterfaceStyle` and `accessibilityContrast` traits.
/// Use these tokens through `@Environment(\.ruulColors)` (preferred for views
/// that need to react to scheme changes) or via the static accessors
/// (`Color.ruulAccentPrimary`, etc.) for convenience.
public struct RuulColors: Sendable {

    // MARK: Backgrounds

    public let backgroundCanvas: Color
    public let backgroundElevated: Color
    public let backgroundRecessed: Color

    // MARK: Surfaces (glass tints, applied on top of system materials)

    public let surfaceGlassThin: Color
    public let surfaceGlassRegular: Color
    public let surfaceGlassThick: Color

    // MARK: Mesh gradient sets

    public let meshCool: [Color]
    public let meshViolet: [Color]
    public let meshAqua: [Color]

    // MARK: Text

    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let textInverse: Color
    public let textAccent: Color

    // MARK: Accent

    public let accentPrimary: Color
    public let accentSecondary: Color
    public let accentSubtle: Color

    // MARK: Semantic

    public let semanticSuccess: Color
    public let semanticWarning: Color
    public let semanticError: Color
    public let semanticInfo: Color

    // MARK: Borders

    public let borderSubtle: Color
    public let borderDefault: Color
    public let borderStrong: Color
    public let borderGlass: Color

    // MARK: Shadow tints (used by RuulElevation)

    public let shadowSm: Color
    public let shadowMd: Color
    public let shadowLg: Color
}

// MARK: - Default palette (resolved per scheme + contrast)

public extension RuulColors {
    static let `default` = RuulColors(
        backgroundCanvas:    .ruulDynamic(light: Hex.lightCanvas, dark: Hex.darkCanvas, lightHighContrast: Hex.lightCanvasHC, darkHighContrast: Hex.darkCanvasHC),
        backgroundElevated:  .ruulDynamic(light: Hex.lightElevated, dark: Hex.darkElevated, lightHighContrast: Hex.lightElevatedHC, darkHighContrast: Hex.darkElevatedHC),
        backgroundRecessed:  .ruulDynamic(light: Hex.lightRecessed, dark: Hex.darkRecessed, lightHighContrast: Hex.lightRecessedHC, darkHighContrast: Hex.darkRecessedHC),

        surfaceGlassThin:    .ruulDynamic(light: Hex.lightGlassThin, dark: Hex.darkGlassThin, lightHighContrast: Hex.lightGlassThinHC, darkHighContrast: Hex.darkGlassThinHC),
        surfaceGlassRegular: .ruulDynamic(light: Hex.lightGlassRegular, dark: Hex.darkGlassRegular, lightHighContrast: Hex.lightGlassRegularHC, darkHighContrast: Hex.darkGlassRegularHC),
        surfaceGlassThick:   .ruulDynamic(light: Hex.lightGlassThick, dark: Hex.darkGlassThick, lightHighContrast: Hex.lightGlassThickHC, darkHighContrast: Hex.darkGlassThickHC),

        meshCool:    Hex.meshCool.map(Color.init(hex:)),
        meshViolet:  Hex.meshViolet.map(Color.init(hex:)),
        meshAqua:    Hex.meshAqua.map(Color.init(hex:)),

        textPrimary:   .ruulDynamic(light: Hex.lightTextPrimary, dark: Hex.darkTextPrimary, lightHighContrast: Hex.lightTextPrimaryHC, darkHighContrast: Hex.darkTextPrimaryHC),
        textSecondary: .ruulDynamic(light: Hex.lightTextSecondary, dark: Hex.darkTextSecondary, lightHighContrast: Hex.lightTextSecondaryHC, darkHighContrast: Hex.darkTextSecondaryHC),
        textTertiary:  .ruulDynamic(light: Hex.lightTextTertiary, dark: Hex.darkTextTertiary, lightHighContrast: Hex.lightTextSecondaryHC, darkHighContrast: Hex.darkTextSecondaryHC),
        textInverse:   .ruulDynamic(light: Hex.lightTextInverse, dark: Hex.darkTextInverse, lightHighContrast: Hex.lightTextInverse, darkHighContrast: Hex.darkTextInverse),
        textAccent:    .ruulDynamic(light: Hex.lightTextAccent, dark: Hex.darkTextAccent, lightHighContrast: Hex.lightTextAccentHC, darkHighContrast: Hex.darkTextAccentHC),

        accentPrimary:   .ruulDynamic(light: Hex.lightAccentPrimary, dark: Hex.darkAccentPrimary, lightHighContrast: Hex.lightAccentPrimaryHC, darkHighContrast: Hex.darkAccentPrimaryHC),
        accentSecondary: .ruulDynamic(light: Hex.lightAccentSecondary, dark: Hex.darkAccentSecondary, lightHighContrast: Hex.lightAccentSecondaryHC, darkHighContrast: Hex.darkAccentSecondaryHC),
        accentSubtle:    .ruulDynamicAlpha(light: Hex.lightAccentPrimary, lightAlpha: 0.10, dark: Hex.darkAccentPrimary, darkAlpha: 0.15, lightHighContrastAlpha: 0.20, darkHighContrastAlpha: 0.25),

        semanticSuccess: .ruulDynamic(light: Hex.lightSuccess, dark: Hex.darkSuccess, lightHighContrast: Hex.lightSuccessHC, darkHighContrast: Hex.darkSuccessHC),
        semanticWarning: .ruulDynamic(light: Hex.lightWarning, dark: Hex.darkWarning, lightHighContrast: Hex.lightWarningHC, darkHighContrast: Hex.darkWarningHC),
        semanticError:   .ruulDynamic(light: Hex.lightError, dark: Hex.darkError, lightHighContrast: Hex.lightErrorHC, darkHighContrast: Hex.darkErrorHC),
        semanticInfo:    .ruulDynamic(light: Hex.lightInfo, dark: Hex.darkInfo, lightHighContrast: Hex.lightInfoHC, darkHighContrast: Hex.darkInfoHC),

        borderSubtle:  .ruulDynamicAlpha(light: 0x0F172A, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.06, lightHighContrastAlpha: 0.16, darkHighContrastAlpha: 0.16),
        borderDefault: .ruulDynamicAlpha(light: 0x0F172A, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.10, lightHighContrastAlpha: 0.24, darkHighContrastAlpha: 0.24),
        borderStrong:  .ruulDynamicAlpha(light: 0x0F172A, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.16, lightHighContrastAlpha: 0.36, darkHighContrastAlpha: 0.36),
        borderGlass:   .ruulDynamicAlpha(light: 0xFFFFFF, lightAlpha: 0.70, dark: 0xFFFFFF, darkAlpha: 0.16, lightHighContrastAlpha: 0.80, darkHighContrastAlpha: 0.30),

        shadowSm: .ruulDynamicAlpha(light: 0x0F172A, lightAlpha: 0.04, dark: 0x000000, darkAlpha: 0.30, lightHighContrastAlpha: 0.08, darkHighContrastAlpha: 0.40),
        shadowMd: .ruulDynamicAlpha(light: 0x0F172A, lightAlpha: 0.08, dark: 0x000000, darkAlpha: 0.40, lightHighContrastAlpha: 0.14, darkHighContrastAlpha: 0.50),
        shadowLg: .ruulDynamicAlpha(light: 0x0F172A, lightAlpha: 0.12, dark: 0x000000, darkAlpha: 0.50, lightHighContrastAlpha: 0.20, darkHighContrastAlpha: 0.60)
    )
}

// MARK: - Hex constants (single source of truth, easy to tune)

private enum Hex {
    // Light — Apple Sports vibe: pure white canvas, near-white elevated.
    // Content (event covers) supplies all the color; chrome stays monochrome.
    static let lightCanvas: UInt32 = 0xFFFFFF
    static let lightElevated: UInt32 = 0xF5F5F7
    static let lightRecessed: UInt32 = 0xEEEEF0
    static let lightCanvasHC: UInt32 = 0xFFFFFF
    static let lightElevatedHC: UInt32 = 0xFFFFFF
    static let lightRecessedHC: UInt32 = 0xE0E0E2

    static let lightGlassThin: UInt32 = 0xFFFFFF
    static let lightGlassRegular: UInt32 = 0xFFFFFF
    static let lightGlassThick: UInt32 = 0xFFFFFF
    static let lightGlassThinHC: UInt32 = 0xFFFFFF
    static let lightGlassRegularHC: UInt32 = 0xFFFFFF
    static let lightGlassThickHC: UInt32 = 0xFFFFFF

    static let lightTextPrimary: UInt32 = 0x000000
    static let lightTextSecondary: UInt32 = 0x6B6B6F
    static let lightTextTertiary: UInt32 = 0xA1A1A6
    static let lightTextInverse: UInt32 = 0xFFFFFF
    // textAccent now mirrors textPrimary — Apple Sports doesn't use a brand
    // accent color for inline text; emphasis comes from weight + size.
    static let lightTextAccent: UInt32 = 0x000000
    static let lightTextPrimaryHC: UInt32 = 0x000000
    static let lightTextSecondaryHC: UInt32 = 0x3A3A3C
    static let lightTextAccentHC: UInt32 = 0x000000

    // Apple Sports — fully monochrome accent. App chrome (FAB, focus rings,
    // primary buttons) is pure black in light mode. Color identity lives in
    // event covers (saturated mesh gradients) and semantic states.
    static let lightAccentPrimary: UInt32 = 0x000000
    static let lightAccentSecondary: UInt32 = 0x1C1C1E
    static let lightAccentPrimaryHC: UInt32 = 0x000000
    static let lightAccentSecondaryHC: UInt32 = 0x000000

    static let lightSuccess: UInt32 = 0x10B981
    static let lightWarning: UInt32 = 0xF59E0B
    static let lightError: UInt32 = 0xEF4444
    static let lightInfo: UInt32 = 0x3B82F6
    static let lightSuccessHC: UInt32 = 0x047857
    static let lightWarningHC: UInt32 = 0xB45309
    static let lightErrorHC: UInt32 = 0xB91C1C
    static let lightInfoHC: UInt32 = 0x1D4ED8

    // Dark — Apple Sports vibe: near-OLED black canvas, subtle elevation
    // step. NOT navy/blue. Lets covers + scores pop with maximum contrast.
    static let darkCanvas: UInt32 = 0x000000
    static let darkElevated: UInt32 = 0x1C1C1E
    static let darkRecessed: UInt32 = 0x0A0A0B
    static let darkCanvasHC: UInt32 = 0x000000
    static let darkElevatedHC: UInt32 = 0x121214
    static let darkRecessedHC: UInt32 = 0x000000

    static let darkGlassThin: UInt32 = 0xFFFFFF
    static let darkGlassRegular: UInt32 = 0xFFFFFF
    static let darkGlassThick: UInt32 = 0xFFFFFF
    static let darkGlassThinHC: UInt32 = 0xFFFFFF
    static let darkGlassRegularHC: UInt32 = 0xFFFFFF
    static let darkGlassThickHC: UInt32 = 0xFFFFFF

    static let darkTextPrimary: UInt32 = 0xFFFFFF
    static let darkTextSecondary: UInt32 = 0x9A9A9F
    static let darkTextTertiary: UInt32 = 0x636367
    static let darkTextInverse: UInt32 = 0x000000
    // textAccent mirrors textPrimary in dark too — pure white inline emphasis.
    static let darkTextAccent: UInt32 = 0xFFFFFF
    static let darkTextPrimaryHC: UInt32 = 0xFFFFFF
    static let darkTextSecondaryHC: UInt32 = 0xD1D1D6
    static let darkTextAccentHC: UInt32 = 0xFFFFFF

    // Apple Sports — fully monochrome accent in dark mode too. Pure white
    // for FAB / primary buttons / focus rings on the near-OLED background.
    static let darkAccentPrimary: UInt32 = 0xFFFFFF
    static let darkAccentSecondary: UInt32 = 0xE5E5E7
    static let darkAccentPrimaryHC: UInt32 = 0xFFFFFF
    static let darkAccentSecondaryHC: UInt32 = 0xFFFFFF

    static let darkSuccess: UInt32 = 0x34D399
    static let darkWarning: UInt32 = 0xFBBF24
    static let darkError: UInt32 = 0xF87171
    static let darkInfo: UInt32 = 0x60A5FA
    static let darkSuccessHC: UInt32 = 0x6EE7B7
    static let darkWarningHC: UInt32 = 0xFCD34D
    static let darkErrorHC: UInt32 = 0xFCA5A5
    static let darkInfoHC: UInt32 = 0x93C5FD

    // Monochrome meshes — very subtle near-canvas variations, Luma/Apple-Sports
    // aesthetic. No violet, blue, or color tint. The 9 stops cluster tightly
    // around a near-canvas value so MeshGradient renders almost flat with
    // gentle illumination, not a colored gradient.
    static let meshCool: [UInt32] = [
        0xF7F8FA, 0xF2F4F7, 0xF6F8FB, 0xF0F2F5, 0xF4F6F9, 0xEDEFF3, 0xF1F3F6, 0xEAECEF, 0xF5F7FA
    ]
    static let meshViolet: [UInt32] = [
        0xF8F8F9, 0xF3F3F4, 0xF7F7F8, 0xF1F1F2, 0xF5F5F6, 0xEEEEEF, 0xF2F2F3, 0xEBEBEC, 0xF6F6F7
    ]
    static let meshAqua: [UInt32] = [
        0xF7F8F8, 0xF2F4F4, 0xF6F7F7, 0xF0F2F2, 0xF4F6F6, 0xEDEFEF, 0xF1F3F3, 0xEAECEC, 0xF5F7F7
    ]
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    init(hex: UInt32, alpha: Double) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Resolve a different hex per scheme + contrast at runtime via UIKit traits.
    static func ruulDynamic(
        light: UInt32,
        dark: UInt32,
        lightHighContrast: UInt32,
        darkHighContrast: UInt32
    ) -> Color {
        Color(uiColor: UIColor { trait in
            let isHighContrast = trait.accessibilityContrast == .high
            switch (trait.userInterfaceStyle, isHighContrast) {
            case (.dark, true):  return UIColor(rgb: darkHighContrast)
            case (.dark, false): return UIColor(rgb: dark)
            case (_, true):      return UIColor(rgb: lightHighContrast)
            default:             return UIColor(rgb: light)
            }
        })
    }

    /// Same shape but with per-mode alpha (used for borders, shadows, subtle tints).
    static func ruulDynamicAlpha(
        light: UInt32,
        lightAlpha: Double,
        dark: UInt32,
        darkAlpha: Double,
        lightHighContrastAlpha: Double,
        darkHighContrastAlpha: Double
    ) -> Color {
        Color(uiColor: UIColor { trait in
            let isHighContrast = trait.accessibilityContrast == .high
            switch (trait.userInterfaceStyle, isHighContrast) {
            case (.dark, true):  return UIColor(rgb: dark, alpha: darkHighContrastAlpha)
            case (.dark, false): return UIColor(rgb: dark, alpha: darkAlpha)
            case (_, true):      return UIColor(rgb: light, alpha: lightHighContrastAlpha)
            default:             return UIColor(rgb: light, alpha: lightAlpha)
            }
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32, alpha: Double = 1.0) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: CGFloat(alpha))
    }
}

// MARK: - Static accessors (convenience for views that don't need env reactivity)

public extension Color {
    static var ruulBackgroundCanvas: Color    { RuulColors.default.backgroundCanvas }
    static var ruulBackgroundElevated: Color  { RuulColors.default.backgroundElevated }
    static var ruulBackgroundRecessed: Color  { RuulColors.default.backgroundRecessed }

    static var ruulSurfaceGlassThin: Color    { RuulColors.default.surfaceGlassThin }
    static var ruulSurfaceGlassRegular: Color { RuulColors.default.surfaceGlassRegular }
    static var ruulSurfaceGlassThick: Color   { RuulColors.default.surfaceGlassThick }

    static var ruulTextPrimary: Color    { RuulColors.default.textPrimary }
    static var ruulTextSecondary: Color  { RuulColors.default.textSecondary }
    static var ruulTextTertiary: Color   { RuulColors.default.textTertiary }
    static var ruulTextInverse: Color    { RuulColors.default.textInverse }
    static var ruulTextAccent: Color     { RuulColors.default.textAccent }

    static var ruulAccentPrimary: Color   { RuulColors.default.accentPrimary }
    static var ruulAccentSecondary: Color { RuulColors.default.accentSecondary }
    static var ruulAccentSubtle: Color    { RuulColors.default.accentSubtle }

    static var ruulSemanticSuccess: Color { RuulColors.default.semanticSuccess }
    static var ruulSemanticWarning: Color { RuulColors.default.semanticWarning }
    static var ruulSemanticError: Color   { RuulColors.default.semanticError }
    static var ruulSemanticInfo: Color    { RuulColors.default.semanticInfo }

    static var ruulBorderSubtle: Color   { RuulColors.default.borderSubtle }
    static var ruulBorderDefault: Color  { RuulColors.default.borderDefault }
    static var ruulBorderStrong: Color   { RuulColors.default.borderStrong }
    static var ruulBorderGlass: Color    { RuulColors.default.borderGlass }

    /// Modal scrim / dimming overlay (Color.black.opacity(0.35) replacement).
    /// Adapts: stronger in light mode (so dim is visible) vs dark mode.
    static var ruulOverlayDim: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.0, alpha: 0.55)
                : UIColor(white: 0.0, alpha: 0.35)
        })
    }

    /// Decorative highlight overlay used for soft inner glows on textured
    /// surfaces (mesh covers, etc). Subtle white wash.
    static var ruulOverlayHighlight: Color {
        Color(uiColor: UIColor { trait in
            UIColor(white: 1.0, alpha: trait.userInterfaceStyle == .dark ? 0.10 : 0.18)
        })
    }
}
