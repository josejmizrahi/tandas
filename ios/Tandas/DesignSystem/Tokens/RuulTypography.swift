import SwiftUI

/// Typography tokens for the ruul design system.
///
/// Currently uses SF Pro (system font) as a placeholder. To swap to a custom
/// display face later, change only the bodies of the static accessors below
/// from `Font.system(...)` to `Font.custom("YourFont-Weight", size:)`.
///
/// Letter-spacing (tracking) is applied via the `.ruulTracking()` modifier
/// returned alongside each token, since `Font` does not embed tracking.
public enum RuulTypography {

    // MARK: - Display

    /// Brand wordmark — for the "ruul" splash on Welcome screens.
    public static let wordmark       = RuulTextStyle(font: .system(size: 88, weight: .bold,     design: .default), tracking: -2.0,  lineHeight: 1.0)
    public static let displayHero    = RuulTextStyle(font: .system(size: 54, weight: .bold,     design: .default), tracking: -2.16, lineHeight: 1.05)
    public static let displayLarge   = RuulTextStyle(font: .system(size: 44, weight: .bold,     design: .default), tracking: -1.32, lineHeight: 1.08)
    public static let displayMedium  = RuulTextStyle(font: .system(size: 34, weight: .semibold, design: .default), tracking: -0.85, lineHeight: 1.10)

    // MARK: - Title / Headline

    public static let titleLarge     = RuulTextStyle(font: .system(size: 28, weight: .semibold, design: .default), tracking: -0.56, lineHeight: 1.15)
    public static let title          = RuulTextStyle(font: .system(size: 22, weight: .semibold, design: .default), tracking: -0.33, lineHeight: 1.20)
    public static let headline       = RuulTextStyle(font: .system(size: 18, weight: .semibold, design: .default), tracking: -0.18, lineHeight: 1.30)

    // MARK: - Body

    public static let bodyLarge      = RuulTextStyle(font: .system(size: 17, weight: .regular,  design: .default), tracking: -0.085, lineHeight: 1.45)
    public static let body           = RuulTextStyle(font: .system(size: 15, weight: .regular,  design: .default), tracking: 0,     lineHeight: 1.50)
    public static let callout        = RuulTextStyle(font: .system(size: 14, weight: .medium,   design: .default), tracking: 0,     lineHeight: 1.40)

    // MARK: - Caption / Footnote

    public static let caption        = RuulTextStyle(font: .system(size: 12, weight: .medium,   design: .default), tracking: 0.12, lineHeight: 1.35)
    public static let footnote       = RuulTextStyle(font: .system(size: 11, weight: .medium,   design: .default), tracking: 0.55, lineHeight: 1.30, textCase: .uppercase)

    // MARK: - Mono (numbers, OTP)

    public static let mono           = RuulTextStyle(font: .system(size: 14, weight: .regular,  design: .monospaced), tracking: 0, lineHeight: 1.40)
    public static let monoLarge      = RuulTextStyle(font: .system(size: 24, weight: .semibold, design: .monospaced), tracking: -0.24, lineHeight: 1.10)
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
//
// TODO: replace bodies with Font.custom("YourFont-Weight", size:) once the
// final display face is chosen. No callers in DesignSystem/Primitives or
// Patterns reference SF Pro directly.

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
