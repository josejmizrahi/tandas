import SwiftUI
import RuulCore

/// Raíz de la app MVP 2.0. Tres gates en orden:
///
/// 1. **Sesión** (`SessionStore`): bootstrapping → signedOut → signedIn.
///    Usuarios anónimos NO entran (regla F.2).
/// 2. **Actor** (`CurrentActorStore`): `ensure_person_actor()` debe resolver
///    antes de mostrar contenido.
/// 3. **Contexto** (`ContextShell`): la app entera opera desde el contexto
///    activo.
public struct RuulAppShell: View {
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw: String = AppearancePreference.system.rawValue
    @State private var container: DependencyContainer

    public init(container: DependencyContainer = DependencyContainer()) {
        _container = State(initialValue: container)
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    public var body: some View {
        content
            .preferredColorScheme(appearance.colorScheme)
            .task {
                container.bootstrap()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch container.sessionStore.state {
        case .bootstrapping:
            SessionLoadingView()

        case .signedOut:
            SignedOutView(authService: container.authService)

        case .signedIn(let session):
            if session.user.isAnonymous {
                // Regla F.2: anon no entra. Forzar sign-in real.
                SignedOutView(authService: container.authService)
            } else {
                actorGate
            }
        }
    }

    /// Gate 2: el person actor debe existir antes de entrar al shell.
    @ViewBuilder
    private var actorGate: some View {
        switch container.currentActorStore.phase {
        case .idle, .loading:
            SessionLoadingView(message: "Preparando tu cuenta…")
                .task { await container.currentActorStore.load() }

        case .failed(let message):
            ErrorStateView(title: "No pudimos cargar tu cuenta", message: message) {
                Task { await container.currentActorStore.load() }
            }

        case .loaded:
            ContextShell(container: container)
        }
    }
}

#Preview("Shell demo") {
    RuulAppShell(container: .demo())
}
