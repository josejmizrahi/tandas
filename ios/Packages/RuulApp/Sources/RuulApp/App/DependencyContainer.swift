import Foundation
import Supabase
import RuulCore

/// Dependencias long-lived de la app. Los stores de feature (Members,
/// Resources, Events, …) NO viven aquí: cada pantalla crea el suyo con
/// `@State` y el `rpc` compartido — así un cambio de contexto nunca muestra
/// datos viejos de otro contexto.
@MainActor
public final class DependencyContainer {

    // MARK: - Backend

    public let authService: any AuthService
    public let rpc: any RuulRPCClient

    // MARK: - Stores long-lived

    public let sessionStore: SessionStore
    public let currentActorStore: CurrentActorStore
    public let contextStore: ContextStore
    public let actorCapabilitiesStore: ActorCapabilitiesStore
    public let invitationsStore: InvitationsStore
    public let resourceTypeCatalogStore: ResourceTypeCatalogStore

    /// Rutea universal links / ruul:// (hoy: invitaciones).
    public let deepLinks: DeepLinkRouter

    // MARK: - Init live

    public init() {
        let client = SupabaseEnvironment.shared
        let auth = LiveAuthService(client: client)
        let rpcClient = SupabaseRuulRPCClient(client: client)

        self.authService = auth
        self.rpc = rpcClient
        self.sessionStore = SessionStore(authService: auth)
        self.currentActorStore = CurrentActorStore(rpc: rpcClient)
        self.contextStore = ContextStore(rpc: rpcClient)
        self.actorCapabilitiesStore = ActorCapabilitiesStore(rpc: rpcClient)
        self.invitationsStore = InvitationsStore(rpc: rpcClient)
        self.resourceTypeCatalogStore = ResourceTypeCatalogStore(rpc: rpcClient)
        self.deepLinks = DeepLinkRouter()
    }

    // MARK: - Init inyectable (previews / tests / UI tests)

    public init(authService: any AuthService, rpc: any RuulRPCClient) {
        self.authService = authService
        self.rpc = rpc
        self.sessionStore = SessionStore(authService: authService)
        self.currentActorStore = CurrentActorStore(rpc: rpc)
        self.contextStore = ContextStore(rpc: rpc)
        self.actorCapabilitiesStore = ActorCapabilitiesStore(rpc: rpc)
        self.invitationsStore = InvitationsStore(rpc: rpc)
        self.resourceTypeCatalogStore = ResourceTypeCatalogStore(rpc: rpc)
        self.deepLinks = DeepLinkRouter()
    }

    /// Container demo: mock client seedeado con el mundo del founder +
    /// sesión mock ya iniciada. Para previews del shell completo.
    public static func demo() -> DependencyContainer {
        let mock = MockRuulRPCClient.demo()
        let session = AppSession(
            user: AppUser(id: MockRuulRPCClient.DemoIds.jose, email: nil, phone: "+5215555550001"),
            accessToken: "demo-token"
        )
        return DependencyContainer(authService: MockAuthService(initialSession: session), rpc: mock)
    }

    // MARK: - Ciclo de vida

    /// Arranca la suscripción de sesión. Idempotente.
    public func bootstrap() {
        sessionStore.bootstrap()
    }

    /// Limpia todo el estado al cerrar sesión.
    public func signOut() async {
        await sessionStore.signOut()
        currentActorStore.reset()
        contextStore.reset()
        actorCapabilitiesStore.reset()
        invitationsStore.reset()
        resourceTypeCatalogStore.reset()
    }
}
