import Foundation
import Testing
@testable import RuulCore

@Suite("SessionStore")
struct SessionStoreTests {

    @Test("bootstrap with no session lands on .signedOut")
    @MainActor
    func bootstrapEmpty() async throws {
        let auth = MockAuthService()
        let store = SessionStore(authService: auth)
        store.bootstrap()
        // MockAuthService yields the current value on subscribe; a short
        // wait lets the bootstrap Task run and apply the initial nil.
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state == .signedOut)
        store.stop()
    }

    @Test("session signal moves state to .signedIn(AppSession)")
    @MainActor
    func signsIn() async throws {
        let auth = MockAuthService()
        let store = SessionStore(authService: auth)
        store.bootstrap()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state == .signedOut)

        try await auth.sendPhoneOTP("+5215555550000")
        let session = try await auth.verifyPhoneOTP("+5215555550000", code: "123456")
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.state == .signedIn(session))
        #expect(store.state.isAuthenticated)
        #expect(store.state.session?.user.phone == "+5215555550000")
        store.stop()
    }

    @Test("signOut sets state to .signedOut synchronously")
    @MainActor
    func signsOut() async throws {
        let auth = MockAuthService()
        try await auth.sendPhoneOTP("+5215555550000")
        _ = try await auth.verifyPhoneOTP("+5215555550000", code: "123456")
        let store = SessionStore(authService: auth)
        store.bootstrap()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state.isAuthenticated)

        await store.signOut()
        #expect(store.state == .signedOut)
        store.stop()
    }

    @Test("bootstrap is idempotent — calling twice replaces the prior task")
    @MainActor
    func bootstrapIdempotent() async throws {
        let auth = MockAuthService()
        let store = SessionStore(authService: auth)
        store.bootstrap()
        store.bootstrap()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state == .signedOut)
        store.stop()
    }
}
