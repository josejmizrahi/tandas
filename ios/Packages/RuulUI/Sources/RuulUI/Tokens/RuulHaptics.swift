import SwiftUI
import UIKit

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
/// - Cambio de grupo activo: `.groupSwitch`
public enum RuulHaptic: Sendable {
    case selection
    case soft
    case light
    case medium
    case heavy
    case success
    case warning
    case error
    case groupSwitch  // DS v3 §2.8 — selectionChanged() feedback al cambiar grupo

    public var feedback: SensoryFeedback {
        switch self {
        case .selection:    return .selection
        case .soft:         return .impact(weight: .light, intensity: 0.6)
        case .light:        return .impact(weight: .light)
        case .medium:       return .impact(weight: .medium)
        case .heavy:        return .impact(weight: .heavy)
        case .success:      return .success
        case .warning:      return .warning
        case .error:        return .error
        case .groupSwitch:  return .selection  // mismo que selection — semantic distinction
        }
    }

    /// Disparo imperativo (no-modifier) del haptic. Útil dentro de closures
    /// (`Button { ... }`) donde pasar un trigger por `sensoryFeedback` sería
    /// más verboso.
    @MainActor
    public func trigger() {
        switch self {
        case .selection, .groupSwitch:
            let g = UISelectionFeedbackGenerator()
            g.prepare()
            g.selectionChanged()
        case .soft:
            let g = UIImpactFeedbackGenerator(style: .light)
            g.prepare()
            g.impactOccurred(intensity: 0.6)
        case .light:
            let g = UIImpactFeedbackGenerator(style: .light)
            g.prepare()
            g.impactOccurred()
        case .medium:
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.prepare()
            g.impactOccurred()
        case .heavy:
            let g = UIImpactFeedbackGenerator(style: .heavy)
            g.prepare()
            g.impactOccurred()
        case .success:
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.success)
        case .warning:
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.warning)
        case .error:
            let g = UINotificationFeedbackGenerator()
            g.prepare()
            g.notificationOccurred(.error)
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
