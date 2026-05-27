import Foundation

/// High-level auth lifecycle for the Foundation iOS surface.
///
/// `SessionStore` exposes this so views can branch between the loading
/// placeholder, the sign-in flow, and the authenticated app shell without
/// reaching into `AuthService` directly. Reuses the existing `AppSession`
/// declared in `Supabase/AuthService.swift` — Foundation does not introduce
/// a parallel session type.
public enum AuthState: Sendable, Equatable {
    /// Initial state at app launch — `SessionStore` has not received the
    /// first value from `AuthService.sessionStream` yet. UI shows a neutral
    /// splash; never persists for more than a tick in practice.
    case bootstrapping

    /// No active session (signed out or never signed in). UI routes to
    /// the OTP/Apple sign-in entry point.
    case signedOut

    /// Authenticated session present. The associated `AppSession` carries
    /// the `AppUser` (id, email, phone, isAnonymous) plus the access token.
    case signedIn(AppSession)
}

public extension AuthState {
    /// `nil` until the bootstrap stream emits its first value or after sign-out.
    var session: AppSession? {
        if case .signedIn(let session) = self { return session }
        return nil
    }

    var isAuthenticated: Bool {
        if case .signedIn = self { return true }
        return false
    }
}
