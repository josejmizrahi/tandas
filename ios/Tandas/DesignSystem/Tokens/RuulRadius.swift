import CoreGraphics

/// Corner-radius tokens.
///
/// Semantic guidelines:
/// - Buttons: `pill` (default) or `lg` (rectangular)
/// - Cards: `lg`
/// - Modal sheets: `xl` (top corners)
/// - Avatar: `circle`
/// - Input fields: `md`
/// - Chips: `pill`
public enum RuulRadius {
    public static let none:   CGFloat = 0
    public static let sm:     CGFloat = 8
    public static let md:     CGFloat = 14
    public static let lg:     CGFloat = 20
    public static let xl:     CGFloat = 28
    public static let pill:   CGFloat = 999
    public static let circle: CGFloat = 9999
}
