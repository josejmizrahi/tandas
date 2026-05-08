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
    public static let md:     CGFloat = 12       // input fields, small cards
    public static let lg:     CGFloat = 16       // cards (Luma/Apple Sports default)
    public static let xl:     CGFloat = 20       // hero tiles, modal sheet tops
    public static let pill:   CGFloat = 999
    public static let circle: CGFloat = 9999
}
