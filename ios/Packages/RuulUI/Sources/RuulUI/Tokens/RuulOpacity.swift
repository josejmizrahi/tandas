import SwiftUI

/// Opacity tokens.
public enum RuulOpacity {
    /// Used for in-flight / disabled interactive surfaces (cast buttons
    /// during isCasting, sheet submit during isSubmitting, etc.).
    /// Visually communicates "you can't tap this right now" without
    /// hiding the affordance entirely.
    public static let disabled: Double = 0.5
}
