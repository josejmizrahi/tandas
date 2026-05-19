import SwiftUI

/// Typography tokens for the ruul design system.
///
/// Display + text styles render in **Inter Variable** (bundled in the
/// app via `Tandas/Resources/Fonts/InterVariable.ttf`, registered through
/// `Info.plist`'s `UIAppFonts`). Monospaced styles continue to use the
/// system monospaced face — Inter doesn't ship a mono cut, and matching
/// numerics for stats/OTPs read better in SF Mono anyway.
public enum RuulTypography {

    /// PostScript name of the bundled variable font. Variable axes are
    /// driven by `.weight(...)` after construction so we never have to
    /// know individual cut names.
    fileprivate static let interFamily = "InterVariable"

    /// Returns the Inter custom font for proportional styles, falling
    /// back to system for monospaced. Variable-axis weight is applied
    /// post-hoc so the same family name works for every weight.
    fileprivate static func interFont(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        switch design {
        case .monospaced:
            return .system(size: size, weight: weight, design: .monospaced)
        default:
            return .custom(interFamily, size: size).weight(weight)
        }
    }

    // MARK: - Display

    /// Brand wordmark — for the "ruul" splash on Welcome screens.
    public static let wordmark       = RuulTextStyle(font: interFont(size: 88, weight: .bold,     design: .default), tracking: -2.0,  lineHeight: 1.0)
    public static let displayHero    = RuulTextStyle(font: interFont(size: 54, weight: .bold,     design: .default), tracking: -2.16, lineHeight: 1.05)
    public static let displayLarge   = RuulTextStyle(font: interFont(size: 44, weight: .bold,     design: .default), tracking: -1.32, lineHeight: 1.08)
    public static let displayMedium  = RuulTextStyle(font: interFont(size: 34, weight: .semibold, design: .default), tracking: -0.85, lineHeight: 1.10)

    // MARK: - Title / Headline

    public static let titleLarge     = RuulTextStyle(font: interFont(size: 28, weight: .semibold, design: .default), tracking: -0.56, lineHeight: 1.15)
    public static let title          = RuulTextStyle(font: interFont(size: 22, weight: .semibold, design: .default), tracking: -0.33, lineHeight: 1.20)
    public static let headline       = RuulTextStyle(font: interFont(size: 18, weight: .semibold, design: .default), tracking: -0.18, lineHeight: 1.30)

    // MARK: - Body

    public static let bodyLarge      = RuulTextStyle(font: interFont(size: 17, weight: .regular,  design: .default), tracking: -0.085, lineHeight: 1.45)
    public static let body           = RuulTextStyle(font: interFont(size: 15, weight: .regular,  design: .default), tracking: 0,     lineHeight: 1.50)
    public static let callout        = RuulTextStyle(font: interFont(size: 14, weight: .medium,   design: .default), tracking: 0,     lineHeight: 1.40)

    // MARK: - Caption / Footnote

    public static let caption        = RuulTextStyle(font: interFont(size: 12, weight: .medium,   design: .default), tracking: 0.12, lineHeight: 1.35)
    public static let footnote       = RuulTextStyle(font: interFont(size: 11, weight: .medium,   design: .default), tracking: 0.55, lineHeight: 1.30, textCase: .uppercase)

    // MARK: - Apple Sports section labels
    //
    // Tracking-uppercase MONOSPACE bold — for "PRÓXIMOS", "INVITADOS",
    // "EN VIVO" section dividers and stat readouts. Distinct from .footnote
    // which is design-default proportional.
    public static let sectionLabel   = RuulTextStyle(font: interFont(size: 11, weight: .bold,     design: .monospaced), tracking: 0.8, lineHeight: 1.30, textCase: .uppercase)
    public static let sectionLabelLg = RuulTextStyle(font: interFont(size: 13, weight: .bold,     design: .monospaced), tracking: 0.6, lineHeight: 1.30, textCase: .uppercase)

    // MARK: - Mono (numbers, OTP)

    public static let mono           = RuulTextStyle(font: interFont(size: 14, weight: .regular,  design: .monospaced), tracking: 0, lineHeight: 1.40)
    public static let monoLarge      = RuulTextStyle(font: interFont(size: 24, weight: .semibold, design: .monospaced), tracking: -0.24, lineHeight: 1.10)
    /// Stat numerals — for counts like "12 van", scores, etc.
    public static let statSmall      = RuulTextStyle(font: interFont(size: 13, weight: .bold,     design: .monospaced), tracking: 0,     lineHeight: 1.20)
    public static let statMedium     = RuulTextStyle(font: interFont(size: 17, weight: .bold,     design: .monospaced), tracking: -0.10, lineHeight: 1.15)
    public static let statHero       = RuulTextStyle(font: interFont(size: 48, weight: .heavy,    design: .monospaced), tracking: -1.20, lineHeight: 1.05)

    // MARK: - Pass 3 Task 4 additions — used by 3+ Features/ sites without a clean prior match.

    /// 22pt medium — section sub-headers, sheet titles where semibold is too heavy.
    public static let titleMedium    = RuulTextStyle(font: interFont(size: 22, weight: .medium,   design: .default), tracking: -0.22, lineHeight: 1.20)

    /// 18pt medium — headlines that need a lighter touch than `.headline` (18pt semibold).
    public static let headlineMedium = RuulTextStyle(font: interFont(size: 18, weight: .medium,   design: .default), tracking: -0.18, lineHeight: 1.30)

    /// 16pt semibold — sub-section headers, action row labels.
    public static let subheadSemibold = RuulTextStyle(font: interFont(size: 16, weight: .semibold, design: .default), tracking: -0.10, lineHeight: 1.35)

    /// 16pt medium — secondary action labels, list row secondary text.
    public static let subheadMedium  = RuulTextStyle(font: interFont(size: 16, weight: .medium,   design: .default), tracking: -0.10, lineHeight: 1.35)

    /// 16pt bold — nav bar labels, prominent row titles.
    public static let subheadBold    = RuulTextStyle(font: interFont(size: 16, weight: .bold,     design: .default), tracking: -0.10, lineHeight: 1.35)

    /// 14pt semibold — metadata labels, pill badges, secondary headings.
    public static let labelSemibold  = RuulTextStyle(font: interFont(size: 14, weight: .semibold, design: .default), tracking: 0,     lineHeight: 1.40)

    /// 14pt bold — emphasis within callout-sized text.
    public static let calloutBold    = RuulTextStyle(font: interFont(size: 14, weight: .bold,     design: .default), tracking: 0,     lineHeight: 1.40)

    /// 14pt regular — descriptive body text at callout size.
    public static let calloutRegular = RuulTextStyle(font: interFont(size: 14, weight: .regular,  design: .default), tracking: 0,     lineHeight: 1.40)

    /// 13pt semibold — compact action labels, inline badges.
    public static let labelSmSemibold = RuulTextStyle(font: interFont(size: 13, weight: .semibold, design: .default), tracking: 0,    lineHeight: 1.35)

    /// 11pt semibold — micro-labels, inline status tags.
    public static let microSemibold  = RuulTextStyle(font: interFont(size: 11, weight: .semibold, design: .default), tracking: 0.2,  lineHeight: 1.30)

    /// 12pt bold — emphasis labels at caption size, badge text.
    public static let captionBold    = RuulTextStyle(font: interFont(size: 12, weight: .bold,     design: .default), tracking: 0.12, lineHeight: 1.35)

    /// 10pt bold — badge counts, minimal pill chips.
    public static let microBold      = RuulTextStyle(font: interFont(size: 10, weight: .bold,     design: .default), tracking: 0.2,  lineHeight: 1.25)

    /// 4pt regular — tiny bullet-dot icons used as list bullets alongside caption text.
    public static let bulletDot      = RuulTextStyle(font: interFont(size: 4,  weight: .regular,  design: .default), tracking: 0,    lineHeight: 1.0)

    // MARK: - Block-tree renderer aliases (Phase C, 2026-05-18)

    /// 16pt regular — canonical "subhead" for block body text. Alias for
    /// readability in the new block-tree detail renderer (Phase C).
    public static let subhead        = RuulTextStyle(font: interFont(size: 16, weight: .regular,  design: .default), tracking: -0.10, lineHeight: 1.35)

    /// 12pt semibold — emphasis at caption scale. Sits between `.caption`
    /// (medium) and `.captionBold` (bold). Used for avatar initials and
    /// status badges in the block-tree renderer.
    public static let captionSemibold = RuulTextStyle(font: interFont(size: 12, weight: .semibold, design: .default), tracking: 0.12, lineHeight: 1.35)
}

// MARK: - RuulTextStyle

/// Bundles a font with tracking, line-height, and optional textCase. Apply via
/// `.ruulTextStyle(...)` modifier.
public struct RuulTextStyle: Sendable {
    public let font: Font
    public let tracking: Double
    public let lineHeight: Double
    public let textCase: Text.Case?

    public init(font: Font, tracking: Double, lineHeight: Double, textCase: Text.Case? = nil) {
        self.font = font
        self.tracking = tracking
        self.lineHeight = lineHeight
        self.textCase = textCase
    }
}

// MARK: - View extension

public extension View {
    /// Apply a ruul text style: font + tracking + lineHeight + textCase.
    func ruulTextStyle(_ style: RuulTextStyle) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineHeight - 1.0)
            .textCase(style.textCase)
    }
}

// MARK: - Static Font accessors (when you only need the font, no tracking)

public extension Font {
    static var ruulDisplayHero: Font   { RuulTypography.displayHero.font }
    static var ruulDisplayLarge: Font  { RuulTypography.displayLarge.font }
    static var ruulDisplayMedium: Font { RuulTypography.displayMedium.font }

    static var ruulTitleLarge: Font    { RuulTypography.titleLarge.font }
    static var ruulTitle: Font         { RuulTypography.title.font }
    static var ruulHeadline: Font      { RuulTypography.headline.font }

    static var ruulBodyLarge: Font     { RuulTypography.bodyLarge.font }
    static var ruulBody: Font          { RuulTypography.body.font }
    static var ruulCallout: Font       { RuulTypography.callout.font }

    static var ruulCaption: Font       { RuulTypography.caption.font }
    static var ruulFootnote: Font      { RuulTypography.footnote.font }

    static var ruulMono: Font          { RuulTypography.mono.font }
    static var ruulMonoLarge: Font     { RuulTypography.monoLarge.font }
}
