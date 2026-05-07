import SwiftUI

/// DS doc canonical Font tokens (`docs/DesignSystem.md` §2.2). Additive — does
/// not redefine the existing `ruulTitle/ruulBody/ruulCaption/...` accessors in
/// `RuulTypography.swift`.
public extension Font {
    static var ruulTitleSmall: Font        { .system(.headline, design: .default, weight: .semibold) }
    static var ruulBodyEmphasis: Font      { .system(.body, design: .default, weight: .semibold) }
    static var ruulCaptionEmphasis: Font   { .system(.subheadline, design: .default, weight: .medium) }
    static var ruulCaptionSmall: Font      { .system(.footnote, design: .default, weight: .regular) }

    // Money — tabular digits siempre.
    static var ruulMoneyLarge: Font        { .system(.title, design: .default, weight: .semibold).monospacedDigit() }
    static var ruulMoneyMedium: Font       { .system(.title3, design: .default, weight: .semibold).monospacedDigit() }
    static var ruulMoneySmall: Font        { .system(.body, design: .default, weight: .semibold).monospacedDigit() }

    // Labels (botones, tab bar, etiquetas estructurales).
    static var ruulLabel: Font             { .system(.subheadline, design: .default, weight: .medium) }
    static var ruulLabelSmall: Font        { .system(.caption, design: .default, weight: .medium) }

    // Microcopy (legales, timestamps muy pequeños).
    static var ruulMicro: Font             { .system(.caption2, design: .default, weight: .regular) }

    /// DS v3 §3.2 — para nombre del grupo en items cross-grupos (Home).
    /// Caption + medium weight para legibilidad sin competir con título.
    static var ruulGroupLabel: Font        { .system(.caption, design: .default, weight: .medium) }
}
