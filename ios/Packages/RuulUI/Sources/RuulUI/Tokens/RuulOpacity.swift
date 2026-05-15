import SwiftUI

/// Opacity tokens. Use over raw literals so the design system can
/// retune one place and have every callsite cascade.
public enum RuulOpacity {
    /// Barely-visible — hairline separators, glass fills, ambient
    /// tints. 8% primary text feels like a whisper against canvas.
    public static let subtle: Double = 0.08
    /// Quiet accent — Capsule pill backgrounds, soft chip tints,
    /// tab-bar active fill. Visible but doesn't pop.
    public static let medium: Double = 0.14
    /// In-flight / disabled affordances (cast buttons, submit during
    /// `isSubmitting`). "You can't tap this right now" without hiding.
    public static let disabled: Double = 0.5
}
