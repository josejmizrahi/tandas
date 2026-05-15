import CoreGraphics

/// DS doc canonical names (`docs/DesignSystem.md` §2.4).
/// Values mirror the existing `RuulRadius` tokens so callers can migrate
/// gradually. Fase E removes the legacy two-letter names.
public extension RuulRadius {
    static let small: CGFloat       = sm   // 10
    static let medium: CGFloat      = md   // 14
    static let large: CGFloat       = lg   // 20
    static let extraLarge: CGFloat  = xl   // 28
    /// Semantic alias for content cards — Luma-style 20pt radius.
    static let card: CGFloat        = lg   // 20
    /// Semantic alias for hero / cover surfaces — Tripsy-style 28pt radius.
    static let hero: CGFloat        = xl   // 28
    // pill ya existe en el enum.
}
