import SwiftUI

/// DS doc canonical Font tokens (`docs/DesignSystem.md` §2.2). Additive — does
/// not redefine the existing `ruulTitle/ruulBody/ruulCaption/...` accessors in
/// `RuulTypography.swift`.
///
/// All non-mono faces resolve to Inter Variable, registered as
/// `InterVariable` via `Info.plist`'s `UIAppFonts`. `relativeTo:` keeps
/// Dynamic Type scaling intact — the bundled axis-driven weight is applied
/// after construction.
public extension Font {
    /// Inter-backed alias for a system semantic TextStyle. `size` is the
    /// canonical iOS metric for that TextStyle at the default content size
    /// category, and Dynamic Type still scales it via `relativeTo:`.
    static func ruulInter(_ textStyle: Font.TextStyle, size: CGFloat, weight: Font.Weight) -> Font {
        .custom("InterVariable", size: size, relativeTo: textStyle).weight(weight)
    }

    static var ruulTitleSmall: Font        { ruulInter(.headline,    size: 17, weight: .semibold) }
    static var ruulBodyEmphasis: Font      { ruulInter(.body,        size: 17, weight: .semibold) }
    static var ruulCaptionEmphasis: Font   { ruulInter(.subheadline, size: 15, weight: .medium) }
    static var ruulCaptionSmall: Font      { ruulInter(.footnote,    size: 13, weight: .regular) }

    // Money — tabular digits siempre. Inter ships tabular numerals as an
    // OpenType feature; `.monospacedDigit()` activates them.
    static var ruulMoneyLarge: Font        { ruulInter(.title,  size: 28, weight: .semibold).monospacedDigit() }
    static var ruulMoneyMedium: Font       { ruulInter(.title3, size: 20, weight: .semibold).monospacedDigit() }
    static var ruulMoneySmall: Font        { ruulInter(.body,   size: 17, weight: .semibold).monospacedDigit() }

    // Labels (botones, tab bar, etiquetas estructurales).
    static var ruulLabel: Font             { ruulInter(.subheadline, size: 15, weight: .medium) }
    static var ruulLabelSmall: Font        { ruulInter(.caption,     size: 12, weight: .medium) }

    // Microcopy (legales, timestamps muy pequeños).
    static var ruulMicro: Font             { ruulInter(.caption2,    size: 11, weight: .regular) }

    /// DS v3 §3.2 — para nombre del grupo en items cross-grupos (Home).
    /// Caption + medium weight para legibilidad sin competir con título.
    static var ruulGroupLabel: Font        { ruulInter(.caption,     size: 12, weight: .medium) }
}
