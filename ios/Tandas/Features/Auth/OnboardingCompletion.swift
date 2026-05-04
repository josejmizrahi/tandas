import Foundation

/// Device-level flag that distinguishes a returning logged-out user from a
/// first-time launch. Set after either onboarding flow successfully verifies
/// a real auth identity (phone OTP or Apple). When `true` and the session is
/// nil (user signed out), AuthGate routes to SignInView instead of dragging
/// the user through the entire onboarding again.
///
/// Persists across app launches via UserDefaults; cleared by uninstall or by
/// SignInView's "Crear cuenta nueva" branch.
enum OnboardingCompletion {
    static let userDefaultsKey = "ruul_has_onboarded"

    static func mark() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    static var hasOnboarded: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
