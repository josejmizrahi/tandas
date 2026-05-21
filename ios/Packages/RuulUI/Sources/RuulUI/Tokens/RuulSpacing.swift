import CoreGraphics

/// Spacing tokens — 4pt grid. Used everywhere as `RuulSpacing.s4` (16pt) etc.
///
/// Semantic guidelines:
/// - Card internal padding: `s5` (20)
/// - Card list gap: `s3` (12)
/// - Section gap: `s7` (32)
/// - Screen horizontal margin: `s5` (20)
/// - Input ↔ label: `s2` (8)
/// - Minimum touch target: 44pt (Apple HIG)
public enum RuulSpacing {
    public static let s0:  CGFloat = 0
    public static let s1:  CGFloat = 4
    public static let s2:  CGFloat = 8
    public static let s3:  CGFloat = 12
    public static let s4:  CGFloat = 16
    public static let s5:  CGFloat = 20
    public static let s6:  CGFloat = 24
    public static let s7:  CGFloat = 32
    public static let s8:  CGFloat = 40
    public static let s9:  CGFloat = 48
    public static let s10: CGFloat = 64
    public static let s11: CGFloat = 80
    public static let s12: CGFloat = 96

    /// Apple HIG minimum touch target.
    public static let minTouchTarget: CGFloat = 44

    /// 2pt — line-pair gap inside a single text block.
    public static let s0_5: CGFloat = 2
    /// 6pt — pill-internal padding when 4pt is too tight and 8pt too
    /// airy (status pills, capsule meta badges).
    public static let micro: CGFloat = 6
}
