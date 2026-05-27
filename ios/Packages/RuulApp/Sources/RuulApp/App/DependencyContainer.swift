import Foundation
import Supabase
import RuulCore

/// Single source of long-lived Foundation dependencies. Assembled once at
/// app launch (or per UI test session) and threaded through `RuulAppShell`
/// to every feature view. Construction order is:
///
/// `SupabaseClient` → `AuthService` + `RuulRPCClient`
/// → canonical repositories → @Observable stores.
///
/// Lives at the `RuulApp` boundary because it imports `Supabase` directly
/// (the only place outside `RuulCore/Supabase/`/`RuulCore/API/` allowed to).
/// Views never see it; they get the stores + repos they need.
@MainActor
public final class DependencyContainer {

    // MARK: - Backend wiring

    public let supabaseClient: SupabaseClient
    public let authService: any AuthService
    public let rpcClient: any RuulRPCClient

    /// Kept as a concrete reference so Foundation can call
    /// `signInWithApple(idToken:nonce:)` which lives on
    /// `LiveAuthService` (not on the protocol — the protocol's no-arg
    /// `signInWithApple()` was a placeholder that always throws).
    private let liveAuth: LiveAuthService

    // MARK: - Repositories

    public let groupRepository: CanonicalGroupRepository
    public let inviteRepository: CanonicalInviteRepository
    public let moneyRepository: CanonicalMoneyRepository
    public let profileRepository: CanonicalProfileRepository

    // MARK: - Stores

    public let sessionStore: SessionStore
    public let groupsStore: GroupsStore
    public let currentGroupStore: CurrentGroupStore
    public let moneyStore: MoneyStore
    public let profileStore: ProfileStore

    public init() {
        let client = SupabaseEnvironment.shared
        self.supabaseClient = client

        let auth = LiveAuthService(client: client)
        self.authService = auth
        self.liveAuth = auth

        let rpc = SupabaseRuulRPCClient(client: client)
        self.rpcClient = rpc

        self.groupRepository = CanonicalGroupRepository(rpc: rpc)
        self.inviteRepository = CanonicalInviteRepository(rpc: rpc)
        self.moneyRepository = CanonicalMoneyRepository(rpc: rpc)
        self.profileRepository = CanonicalProfileRepository(rpc: rpc)

        self.sessionStore = SessionStore(authService: auth)
        self.groupsStore = GroupsStore(repository: groupRepository)
        self.currentGroupStore = CurrentGroupStore(repository: groupRepository)
        self.moneyStore = MoneyStore(repository: moneyRepository)
        self.profileStore = ProfileStore(repository: profileRepository)
    }

    /// Kicks off the session subscription so the shell can observe state
    /// transitions. Idempotent; safe to call from `.task`.
    public func bootstrap() {
        sessionStore.bootstrap()
    }

    /// Forwards a completed Sign In with Apple credential to Supabase via
    /// `LiveAuthService`. The view layer owns the `ASAuthorizationController`
    /// dance + nonce generation; it just hands us the verified token + the
    /// matching raw nonce when Apple returns success.
    public func signInWithApple(idToken: String, nonce: String) async throws -> AppSession {
        try await liveAuth.signInWithApple(idToken: idToken, nonce: nonce)
    }
}
