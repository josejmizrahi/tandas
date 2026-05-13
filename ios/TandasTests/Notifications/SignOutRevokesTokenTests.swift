import Testing
import Foundation
import RuulCore
@testable import Tandas

/// Beta 1 Consolidation — W1-1 regression coverage.
///
/// Bug: `app.auth.signOut()` alone left the `notification_tokens` row
/// intact. On a shared family device (parent A signs out, parent B
/// signs in), APNs pushes addressed to A continued to land on the
/// same device — now showing B's user. Cross-user leak.
///
/// Fix: `AppState.signOut()` orchestrates `notifications.revokeTokenIfRegistered()`
/// before `auth.signOut()`. Best-effort revoke (network failure is logged
/// but never blocks sign-out) — ensures the user is always logged out
/// client-side, with the server token row cleared on the happy path.
@Suite("Sign out revokes APNs token")
@MainActor
struct SignOutRevokesTokenTests {
    @Test("revokeTokenIfRegistered with a previously registered token clears the repo")
    func revokesRegisteredToken() async throws {
        let repo = MockNotificationTokenRepository()
        let svc = NotificationService(tokenRepo: repo)

        // Simulate the system handing us a device token.
        await svc.didRegisterDeviceToken(Data([0xCA, 0xFE, 0xBA, 0xBE]))
        let beforeTokens = await repo.tokens
        #expect(beforeTokens == ["cafebabe"])
        #expect(svc.lastDeviceToken == "cafebabe")

        await svc.revokeTokenIfRegistered()

        let afterTokens = await repo.tokens
        #expect(afterTokens.isEmpty)
        #expect(svc.lastDeviceToken == nil)
    }

    @Test("revokeTokenIfRegistered with no token is a safe no-op")
    func noOpWhenNoToken() async throws {
        let repo = MockNotificationTokenRepository()
        let svc = NotificationService(tokenRepo: repo)
        // Never called didRegisterDeviceToken.
        #expect(svc.lastDeviceToken == nil)

        await svc.revokeTokenIfRegistered()

        let tokens = await repo.tokens
        #expect(tokens.isEmpty)
        #expect(svc.lastDeviceToken == nil)
    }

    @Test("revokeTokenIfRegistered swallows repo errors so sign-out is never blocked")
    func swallowsRepoErrors() async throws {
        let repo = ThrowingTokenRepo()
        let svc = NotificationService(tokenRepo: repo)
        await svc.didRegisterDeviceToken(Data([0xDE, 0xAD]))
        #expect(svc.lastDeviceToken == "dead")

        // Should NOT throw even though the repo fails.
        await svc.revokeTokenIfRegistered()

        // Local state must still be cleared so the device is "logged out"
        // from the client's POV even if the server-side revoke failed.
        #expect(svc.lastDeviceToken == nil)
    }
}

private actor ThrowingTokenRepo: NotificationTokenRepository {
    struct Boom: Error {}
    func registerToken(_ token: String) async throws {
        // Allow register so we can reach the revoke path with a token.
    }
    func revokeToken(_ token: String) async throws {
        throw Boom()
    }
}
