import SwiftUI

/// Haptic feedback tokens. Map onto `SensoryFeedback` so they can be passed
/// directly to `.sensoryFeedback(_:trigger:)`.
///
/// Semantic guidelines:
/// - Toggle / picker change: `.selection`
/// - Tap on primary CTA: `.light`
/// - Auto-advance step: `.selection`
/// - Confirmed action (RSVP, paid fine): `.success`
/// - Recoverable warning: `.warning`
/// - Hard error (3 OTP fails, etc.): `.error`
public enum RuulHaptic: Sendable {
    case selection
    case soft
    case light
    case medium
    case heavy
    case success
    case warning
    case error

    public var feedback: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .soft:      return .impact(weight: .light, intensity: 0.6)
        case .light:     return .impact(weight: .light)
        case .medium:    return .impact(weight: .medium)
        case .heavy:     return .impact(weight: .heavy)
        case .success:   return .success
        case .warning:   return .warning
        case .error:     return .error
        }
    }
}

public extension View {
    /// Convenience wrapper around `.sensoryFeedback(_:trigger:)` using a
    /// `RuulHaptic` token.
    func ruulHaptic<T: Equatable>(_ haptic: RuulHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }
}
