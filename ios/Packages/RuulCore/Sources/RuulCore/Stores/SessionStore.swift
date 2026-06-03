import Foundation
import Observation

/// Store `@MainActor` que expone el ciclo de vida de la sesión auth.
/// Se suscribe a `AuthService.sessionStream` una sola vez en `bootstrap()`.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: AuthState = .bootstrapping

    private let authService: any AuthService
    private var sessionTask: Task<Void, Never>?

    public init(authService: any AuthService) {
        self.authService = authService
    }

    /// Preview/test init con estado fijo.
    public init(previewState: AuthState) {
        self.authService = MockAuthService()
        self.state = previewState
    }

    /// Arranca la suscripción a la sesión. Idempotente.
    public func bootstrap() {
        sessionTask?.cancel()
        let stream = authService.sessionStream
        sessionTask = Task { [weak self] in
            for await session in stream {
                self?.apply(session)
            }
        }
    }

    public func stop() {
        sessionTask?.cancel()
        sessionTask = nil
    }

    public func signOut() async {
        do {
            try await authService.signOut()
            state = .signedOut
        } catch {
            // La sesión local ya se limpió aunque la red falle.
            state = .signedOut
        }
    }

    private func apply(_ session: AppSession?) {
        if let session {
            state = .signedIn(session)
        } else {
            state = .signedOut
        }
    }
}
