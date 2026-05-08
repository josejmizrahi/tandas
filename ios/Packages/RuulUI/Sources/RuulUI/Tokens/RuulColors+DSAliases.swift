import SwiftUI

/// DS doc canonical names (`docs/DesignSystem.md` §2.3). All resolve to the
/// existing dynamic-trait tokens declared in `RuulColors.swift`.
public extension Color {
    static var ruulBackground: Color        { ruulBackgroundCanvas }
    static var ruulSurface: Color           { ruulBackgroundElevated }
    static var ruulSurfaceElevated: Color   { ruulBackgroundElevated }

    static var ruulPositive: Color          { ruulSemanticSuccess }
    static var ruulNegative: Color          { ruulSemanticError }
    static var ruulWarning: Color           { ruulSemanticWarning }
    static var ruulInfo: Color              { ruulSemanticInfo }
    static var ruulNeutral: Color           { ruulTextTertiary }

    static var ruulSeparator: Color         { ruulBorderSubtle }
    static var ruulSeparatorOpaque: Color   { ruulBorderDefault }

    static var ruulAccent: Color            { ruulAccentPrimary }
    static var ruulAccentMuted: Color       { ruulAccentSubtle }

    /// Tinted backgrounds para estados (NEW).
    static var ruulPositiveBackground: Color { ruulSemanticSuccess.opacity(0.12) }
    static var ruulNegativeBackground: Color { ruulSemanticError.opacity(0.12) }
    static var ruulWarningBackground: Color  { ruulSemanticWarning.opacity(0.12) }
    static var ruulInfoBackground: Color     { ruulSemanticInfo.opacity(0.12) }
}
