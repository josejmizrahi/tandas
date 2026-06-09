import SwiftUI
import RuulCore

/// Raíz de la app MVP 2.0. Tres gates en orden:
///
/// 1. **Sesión** (`SessionStore`): bootstrapping → signedOut → signedIn.
///    Usuarios anónimos NO entran (regla F.2).
/// 2. **Actor** (`CurrentActorStore`): `ensure_person_actor()` debe resolver
///    antes de mostrar contenido.
/// 3. **Tab shell** (`MainTabShell`, F.NAV.1): tabs Home/Contextos/Crear/
///    Actividad/Yo. La tab Contextos contiene `ContextsListView` con
///    NavigationStack propio que pushea a `ContextDetailViewV2` por contexto.
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
            // Universal links (ruul.mx/invite/CODE) y scheme ruul://.
            // El código queda pendiente en el router hasta pasar los gates.
            .onOpenURL { url in
                container.deepLinks.handle(url)
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
            RuulErrorState(title: "No pudimos cargar tu cuenta", message: message) {
                Task { await container.currentActorStore.load() }
            }

        case .loaded:
            MainTabShell(container: container)
                .modifier(ClaimPlaceholdersGate(container: container))
        }
    }
}

// MARK: - R.5W Slice 4 — Claim placeholders gate

/// Al entrar al tab shell, consulta `find_placeholder_matches_for_me`. Si hay
/// matches (el caller tiene phone/email que coincide con placeholders activos),
/// presenta el sheet de claim. Una sola vez por session — no spamea al user.
private struct ClaimPlaceholdersGate: ViewModifier {
    let container: DependencyContainer

    @State private var matches: [PlaceholderMatch] = []
    @State private var isShowingSheet = false
    @State private var didCheckOnce = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !didCheckOnce else { return }
                didCheckOnce = true
                do {
                    let result = try await container.rpc.findPlaceholderMatchesForMe()
                    if !result.matches.isEmpty {
                        matches = result.matches
                        isShowingSheet = true
                    }
                } catch {
                    // Silent — non-blocking. El user puede invocar manual en futuro.
                }
            }
            .sheet(isPresented: $isShowingSheet) {
                ClaimPlaceholdersSheet(matches: matches, container: container) {
                    isShowingSheet = false
                    // Refresh contextos por si el claim agregó memberships nuevas.
                    Task { await container.contextStore.load() }
                }
            }
    }
}

#Preview("Shell demo") {
    RuulAppShell(container: .demo())
}
