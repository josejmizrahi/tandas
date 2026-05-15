import CoreGraphics

/// Corner-radius tokens.
///
/// Semantic guidelines:
/// - Buttons: `pill` (default) or `lg` (rectangular)
/// - Cards: `lg` (or `card`)
/// - Modal sheets / cover heroes: `xl` (or `hero`)
/// - Avatar: `circle`
/// - Input fields: `md`
/// - Chips: `pill`
///
/// **2026-05-15 base refresh** — scale bumped to land closer to the
/// Luma / Tripsy aesthetic (rounder cards, softer corners). Callers
/// using semantic names (`large`, `extraLarge`, `card`, `hero`) pick
/// up the new values automatically.
public enum RuulRadius {
    public static let none:   CGFloat = 0
    public static let sm:     CGFloat = 10      // chips, small badges
    public static let md:     CGFloat = 14      // input fields, compact cards
    public static let lg:     CGFloat = 20      // cards (Luma-style modern radius)
    public static let xl:     CGFloat = 28      // hero tiles, cover cards, modal sheet tops
    public static let pill:   CGFloat = 999
    public static let circle: CGFloat = 9999
}
