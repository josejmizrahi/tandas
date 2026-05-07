import CoreGraphics

/// DS doc canonical names (per `docs/DesignSystem.md` §2.1).
/// Values mirror the existing `RuulSpacing.s*` tokens so callers can migrate
/// gradually. Fase E removes the s* legacy.
public extension RuulSpacing {
    static let xxs:  CGFloat = 4   // == s1
    static let xs:   CGFloat = 8   // == s2
    static let sm:   CGFloat = 12  // == s3
    static let md:   CGFloat = 16  // == s4
    static let lg:   CGFloat = 20  // == s5
    static let xl:   CGFloat = 24  // == s6
    static let xxl:  CGFloat = 32  // == s7
    static let xxxl: CGFloat = 48  // == s9

    /// Semantic aliases — preferred for new code.
    static let cardPadding: CGFloat   = md   // 16 — internal card padding
    static let screenPadding: CGFloat = lg   // 20 — screen horizontal margin
    static let sectionGap: CGFloat    = xxl  // 32 — between major sections
    static let itemGap: CGFloat       = sm   // 12 — between items in list
}
