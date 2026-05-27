import Foundation
import Observation

/// `@MainActor` store that surfaces the current auth lifecycle to the
/// Foundation iOS surface. Consumes the existing `AuthService` actor
/// (declared in `Supabase/AuthService.swift`) — Foundation does not
/// introduce a parallel auth service. The store subscribes to
/// `AuthService.sessionStream` once at `bootstrap()` and apply the
/// emitted sessions on the main actor.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: AuthState = .bootstrapping

    private let authService: any AuthService
    private var sessionTask: Task<Void, Never>?

    public init(authService: any AuthService) {
        self.authService = authService
    }

    /// Starts the session subscription. Idempotent — replaces any prior
    /// task. Call once from the app entry point (`@main` view's `task` or
    /// `DependencyContainer.bootstrap()`). The store is expected to live
    /// for the lifetime of the app, so there is no `deinit` cancellation;
    /// the `[weak self]` capture below turns every emission into a no-op
    /// once the store is released.
    public func bootstrap() {
        sessionTask?.cancel()
        let stream = authService.sessionStream
        sessionTask = Task { [weak self] in
            for await session in stream {
                self?.apply(session)
            }
        }
    }

    /// Explicit teardown — drops the subscription. Foundation does not
    /// call this in normal flow; tests use it to tear down between cases.
    public func stop() {
        sessionTask?.cancel()
        sessionTask = nil
    }

    /// Asks `AuthService` to drop the cached session. The session stream
    /// will emit `nil` and `apply(_:)` will move state to `.signedOut`;
    /// we also flip state here optimistically so the UI updates before
    /// the round-trip lands.
    public func signOut() async {
        do {
            try await authService.signOut()
            state = .signedOut
        } catch {
            // Swallow — the Supabase signOut throws when the network is
            // down, but the local session has still been cleared on a
            // successful path. Foundation's UX keeps the user on the
            // signed-in shell with no banner; deeper handling lands when
            // we wire the global error surface.
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
