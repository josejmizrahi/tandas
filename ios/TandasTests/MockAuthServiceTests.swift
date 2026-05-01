import Testing
import Foundation
@testable import Tandas

@Suite("MockAuthService")
struct MockAuthServiceTests {
    @Test("starts with no session")
    func startsLoggedOut() async throws {
        let svc = MockAuthService()
        let s = await svc.session
        #expect(s == nil)
    }

    @Test("phone OTP happy path")
    func phoneOTP() async throws {
        let svc = MockAuthService()
        try await svc.sendPhoneOTP("+5215555550000")
        let session = try await svc.verifyPhoneOTP("+5215555550000", code: "123456")
        #expect(session.user.id != UUID())  // any user id
        let after = await svc.session
        #expect(after != nil)
    }

    @Test("wrong OTP throws")
    func wrongOTP() async throws {
        let svc = MockAuthService()
        try await svc.sendPhoneOTP("+5215555550000")
        await #expect(throws: AuthError.invalidOTP) {
            _ = try await svc.verifyPhoneOTP("+5215555550000", code: "999999")
        }
    }

    @Test("signOut clears session")
    func signOutClears() async throws {
        let svc = MockAuthService()
        _ = try await svc.signInWithApple()
        try await svc.signOut()
        let s = await svc.session
        #expect(s == nil)
    }
}
