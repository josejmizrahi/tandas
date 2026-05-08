import Foundation
import CoreGraphics

/// Component size tokens — frame dimensions for avatars, hero images, badges,
/// and other named UI elements. Use over raw literal numbers everywhere.
public enum RuulSize {
    // MARK: - Avatars
    public static let avatarXS:       CGFloat = 24
    public static let avatarSmall:    CGFloat = 32
    public static let avatarMedium:   CGFloat = 40
    public static let avatarLarge:    CGFloat = 56
    public static let avatarHero:     CGFloat = 80
    public static let avatarXLarge:   CGFloat = 96

    // MARK: - Hero images / banners
    public static let heroBanner:     CGFloat = 180
    public static let heroLarge:      CGFloat = 240

    // MARK: - Badges (small overlays on avatars/cards)
    public static let badgeSmall:     CGFloat = 24
    public static let badgeMedium:    CGFloat = 32

    // MARK: - Icon sizes (font-controlled, but useful as constants)
    public static let iconXS:         CGFloat = 12
    public static let iconSmall:      CGFloat = 14
    public static let iconMedium:     CGFloat = 16
    public static let iconLarge:      CGFloat = 22
}

/// Tighter spacing values used between adjacent text lines.
public extension RuulSpacing {
    /// 2pt — for tight stacking inside text blocks (line-pair gaps).
    static let s0_5: CGFloat = 2
}
