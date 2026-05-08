import SwiftUI

/// Motion tokens — spring presets and durations.
///
/// Semantic guidelines:
/// - Selection feedback / quick state changes: `.ruulSnappy`
/// - Modal / sheet appearance: `.ruulSmooth`
/// - Playful / decorative bounce: `.ruulBouncy`
/// - Glass-morph between states: `.ruulMorph`
public extension Animation {
    static let ruulSnappy = Animation.spring(response: 0.30, dampingFraction: 0.85)
    static let ruulSmooth = Animation.spring(response: 0.40, dampingFraction: 0.80)
    static let ruulBouncy = Animation.spring(response: 0.50, dampingFraction: 0.70)
    static let ruulMorph  = Animation.spring(response: 0.60, dampingFraction: 0.85)
}

/// Duration presets for cases where spring doesn't apply (linear loops, fades).
public enum RuulDuration {
    public static let instant: Double = 0.10
    public static let fast:    Double = 0.20
    public static let medium:  Double = 0.35
    public static let slow:    Double = 0.50

    /// Per-step pause for auto-advance flows (e.g. onboarding).
    public static let autoAdvance: Double = 0.60

    /// Skeleton shimmer cycle.
    public static let shimmerCycle: Double = 1.40
}
