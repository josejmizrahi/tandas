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
    // Light
    static let lightCanvas: UInt32 = 0xF7F8FA
    static let lightElevated: UInt32 = 0xFFFFFF
    static let lightRecessed: UInt32 = 0xEFF1F4
    static let lightCanvasHC: UInt32 = 0xFFFFFF
    static let lightElevatedHC: UInt32 = 0xFFFFFF
    static let lightRecessedHC: UInt32 = 0xE5E8ED

    static let lightGlassThin: UInt32 = 0xFFFFFF
    static let lightGlassRegular: UInt32 = 0xFFFFFF
    static let lightGlassThick: UInt32 = 0xFFFFFF
    static let lightGlassThinHC: UInt32 = 0xFFFFFF
    static let lightGlassRegularHC: UInt32 = 0xFFFFFF
    static let lightGlassThickHC: UInt32 = 0xFFFFFF

    static let lightTextPrimary: UInt32 = 0x0A0E1A
    static let lightTextSecondary: UInt32 = 0x475569
    static let lightTextTertiary: UInt32 = 0x94A3B8
    static let lightTextInverse: UInt32 = 0xFFFFFF
    static let lightTextAccent: UInt32 = 0x5B6CFF
    static let lightTextPrimaryHC: UInt32 = 0x000000
    static let lightTextSecondaryHC: UInt32 = 0x1F2937
    static let lightTextAccentHC: UInt32 = 0x3B4FE5

    static let lightAccentPrimary: UInt32 = 0x5B6CFF
    static let lightAccentSecondary: UInt32 = 0x8B5CF6
    static let lightAccentPrimaryHC: UInt32 = 0x3B4FE5
    static let lightAccentSecondaryHC: UInt32 = 0x6D3FE0

    static let lightSuccess: UInt32 = 0x10B981
    static let lightWarning: UInt32 = 0xF59E0B
    static let lightError: UInt32 = 0xEF4444
    static let lightInfo: UInt32 = 0x3B82F6
    static let lightSuccessHC: UInt32 = 0x047857
    static let lightWarningHC: UInt32 = 0xB45309
    static let lightErrorHC: UInt32 = 0xB91C1C
    static let lightInfoHC: UInt32 = 0x1D4ED8

    // Dark
    static let darkCanvas: UInt32 = 0x0A0E1A
    static let darkElevated: UInt32 = 0x131826
    static let darkRecessed: UInt32 = 0x050811
    static let darkCanvasHC: UInt32 = 0x000000
    static let darkElevatedHC: UInt32 = 0x0F1422
    static let darkRecessedHC: UInt32 = 0x000000

    static let darkGlassThin: UInt32 = 0xFFFFFF
    static let darkGlassRegular: UInt32 = 0xFFFFFF
    static let darkGlassThick: UInt32 = 0xFFFFFF
    static let darkGlassThinHC: UInt32 = 0xFFFFFF
    static let darkGlassRegularHC: UInt32 = 0xFFFFFF
    static let darkGlassThickHC: UInt32 = 0xFFFFFF

    static let darkTextPrimary: UInt32 = 0xF8FAFC
    static let darkTextSecondary: UInt32 = 0x94A3B8
    static let darkTextTertiary: UInt32 = 0x64748B
    static let darkTextInverse: UInt32 = 0x0A0E1A
    static let darkTextAccent: UInt32 = 0x818CF8
    static let darkTextPrimaryHC: UInt32 = 0xFFFFFF
    static let darkTextSecondaryHC: UInt32 = 0xCBD5E1
    static let darkTextAccentHC: UInt32 = 0xA5B0FF

    static let darkAccentPrimary: UInt32 = 0x818CF8
    static let darkAccentSecondary: UInt32 = 0xA78BFA
    static let darkAccentPrimaryHC: UInt32 = 0xA5B0FF
    static let darkAccentSecondaryHC: UInt32 = 0xC4A8FF

    static let darkSuccess: UInt32 = 0x34D399
    static let darkWarning: UInt32 = 0xFBBF24
    static let darkError: UInt32 = 0xF87171
    static let darkInfo: UInt32 = 0x60A5FA
    static let darkSuccessHC: UInt32 = 0x6EE7B7
    static let darkWarningHC: UInt32 = 0xFCD34D
    static let darkErrorHC: UInt32 = 0xFCA5A5
    static let darkInfoHC: UInt32 = 0x93C5FD

    // Mesh sets
    static let meshCool: [UInt32] = [0xE8EEFF, 0xDCE7F5, 0xE8F0FF, 0xD8E4FB, 0xEAF1FF, 0xD0DEF7, 0xE2EBFA, 0xCDDDF6, 0xE6EFFF]
    static let meshViolet: [UInt32] = [0xEFE8FF, 0xE5DEF8, 0xF0E8FF, 0xDCD4F2, 0xEAE0FA, 0xD2C4EE, 0xE5DAF6, 0xCDBEEC, 0xEEE6FE]
    static let meshAqua: [UInt32] = [0xE5F4F8, 0xD8EDF5, 0xECF6FA, 0xC8E5F0, 0xDDF0F7, 0xBADCEC, 0xD3EAF3, 0xAED5E8, 0xE8F5FA]
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
