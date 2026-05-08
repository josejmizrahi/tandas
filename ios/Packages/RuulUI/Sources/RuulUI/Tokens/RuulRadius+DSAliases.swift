import CoreGraphics

/// DS doc canonical names (`docs/DesignSystem.md` §2.4).
/// Values mirror the existing `RuulRadius` tokens so callers can migrate
/// gradually. Fase E removes the legacy two-letter names.
public extension RuulRadius {
    static let small: CGFloat       = sm   // 8
    static let medium: CGFloat      = md   // 12
    static let large: CGFloat       = lg   // 16
    static let extraLarge: CGFloat  = xl   // 20
    // pill ya existe en el enum.
}
