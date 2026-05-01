import Testing
import Foundation
import SwiftData
@testable import Tandas

@Suite("InvitedOnboardingCoordinator")
@MainActor
struct InvitedOnboardingCoordinatorTests {

    private func makeCoordinator(
        seedGroup: Group? = nil,
        groupRepo: MockGroupsRepository? = nil,
        otp: MockOTPService = .init()
    ) async throws -> (InvitedOnboardingCoordinator, MockGroupsRepository, MockInviteRepository, MockOTPService) {
        let groups = groupRepo ?? MockGroupsRepository(seed: seedGroup.map { [$0] } ?? [])
        let invites = MockInviteRepository()
        let analytics = MockAnalyticsService()
        let container = try ModelContainer(
            for: OnboardingProgress.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let manager = OnboardingProgressManager(context: container.mainContext)
        let coord = InvitedOnboardingCoordinator(
            inviteCode: seedGroup?.inviteCode ?? "abc12345",
            groupRepo: groups,
            inviteRepo: invites,
            otp: otp,
            analytics: analytics,
            progress: manager
        )
        return (coord, groups, invites, otp)
    }

    private func sampleGroup(code: String) -> Group {
        Group(
            id: UUID(),
            name: "Los Cuates",
            inviteCode: code,
            eventVocabulary: "cena",
            createdBy: UUID(),
            createdAt: .now
        )
    }

    @Test("happy path advances welcome → tour")
    func happyPath() async throws {
        let g = sampleGroup(code: "abc12345")
        let (coord, _, _, otp) = try await makeCoordinator(seedGroup: g)
        await coord.start()
        #expect(coord.preview != nil)
        #expect(coord.currentStep == .welcome)

        await coord.acceptInvitation()
        #expect(coord.currentStep == .identity)

        coord.displayName = "Ana"
        await coord.advanceFromIdentity()
        #expect(coord.currentStep == .phoneVerify)

        coord.phoneE164 = "+5215555551234"
        await coord.advanceFromPhoneVerify()
        #expect(coord.currentStep == .otp)

        otp.verifyResult = .success(())
        await coord.submitOTP(code: "123456")
        #expect(coord.currentStep == .tour)
    }

    @Test("invalid invite code → error")
    func invalidCode() async throws {
        let groups = MockGroupsRepository(seed: [])
        let (coord, _, _, _) = try await makeCoordinator(groupRepo: groups)
        await coord.start()
        #expect(coord.error == .inviteCodeInvalid)
        #expect(coord.preview == nil)
    }

    @Test("OTP 3 fails → tooManyAttempts, stays on otp step")
    func otpThreeStrikes() async throws {
        let g = sampleGroup(code: "abc12345")
        let (coord, _, _, otp) = try await makeCoordinator(seedGroup: g)
        await coord.start()
        await coord.acceptInvitation()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.phoneE164 = "+5215555551234"
        await coord.advanceFromPhoneVerify()

        otp.verifyResult = .failure(.invalidCode)
        await coord.submitOTP(code: "000000")
        await coord.submitOTP(code: "000000")
        await coord.submitOTP(code: "000000")
        #expect(coord.otpAttempts == 3)
        #expect(coord.error == .otpTooManyAttempts)
        #expect(coord.currentStep == .otp)
    }
}
