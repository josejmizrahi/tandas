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

    /// P0.3 — valida la sesión restaurada contra el auth server una sola vez
    /// por proceso. Si el servidor rechaza el token (usuario borrado, JWT
    /// huérfano en Keychain), cierra sesión limpio y la UI vuelve a
    /// SignedOutView en lugar de dejar al usuario en un estado zombie donde
    /// todos los RPCs fallan con errores crípticos. Fallo de red NO desloguea.
    public func verifyRestoredSessionIfNeeded() async {
        guard !didVerifyRestoredSession, case .signedIn = state else { return }
        didVerifyRestoredSession = true
        if await authService.checkSessionValidity() == .invalid {
            await signOut()
        }
    }

    private var didVerifyRestoredSession = false

    private func apply(_ session: AppSession?) {
        if let session {
            state = .signedIn(session)
        } else {
            state = .signedOut
        }
    }
}
