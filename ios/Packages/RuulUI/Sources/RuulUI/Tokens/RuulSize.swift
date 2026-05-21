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
    /// Resource detail cover card (Luma-scale poster). Used by
    /// `ResourceCoverHero` as a rounded-all-sides card inside the
    /// detail screen — large enough to read as a "poster", small
    /// enough that the panel content peeks above the fold.
    public static let coverHero:      CGFloat = 400

    // MARK: - Badges (small overlays on avatars/cards)
    public static let badgeSmall:     CGFloat = 24
    public static let badgeMedium:    CGFloat = 32

    // MARK: - Icon badges (the circle/rounded-square wrappers around
    // SF symbols inside list rows / metadata cells / etc.)
    public static let iconBadgeSmall:  CGFloat = 32
    public static let iconBadgeMedium: CGFloat = 36
    public static let iconBadgeLarge:  CGFloat = 40

    // MARK: - Icon sizes (font-controlled, but useful as constants)
    public static let iconXS:         CGFloat = 12
    public static let iconSmall:      CGFloat = 14
    public static let iconMedium:     CGFloat = 16
    public static let iconLarge:      CGFloat = 22
}

/// Micro-spacing values that sit below the s1 (4pt) base — used for
/// tight inside-text alignments and small pill insets.
public extension RuulSpacing {
    /// 2pt — line-pair gap inside a single text block.
    static let s0_5: CGFloat = 2
    /// 6pt — pill-internal padding when 4pt is too tight and 8pt too
    /// airy (status pills, capsule meta badges).
    static let micro: CGFloat = 6
}
