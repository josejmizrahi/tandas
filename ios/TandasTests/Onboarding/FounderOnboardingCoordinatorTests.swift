import Testing
import Foundation
import SwiftData
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("FounderOnboardingCoordinator")
@MainActor
struct FounderOnboardingCoordinatorTests {

    // MARK: - Helpers

    private func makeCoordinator(
        groupRepo: MockGroupsRepository = .init(),
        inviteRepo: MockInviteRepository = .init(),
        ruleRepo: MockRuleRepository = .init(),
        otp: MockOTPService = .init()
    ) throws -> (FounderOnboardingCoordinator, MockGroupsRepository, MockInviteRepository, MockRuleRepository, MockOTPService, MockAnalyticsService) {
        let analytics = MockAnalyticsService()
        let container = try ModelContainer(
            for: OnboardingProgress.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let manager = OnboardingProgressManager(context: container.mainContext)
        let coord = FounderOnboardingCoordinator(
            groupRepo: groupRepo,
            inviteRepo: inviteRepo,
            ruleRepo: ruleRepo,
            otp: otp,
            analytics: analytics,
            progress: manager
        )
        return (coord, groupRepo, inviteRepo, ruleRepo, otp, analytics)
    }

    // MARK: - Happy path

    @Test("full happy path advances welcome → confirm")
    func happyPath() async throws {
        let (coord, groups, _, rules, otp, _) = try makeCoordinator()
        await coord.start()

        await coord.advanceFromWelcome()
        #expect(coord.currentStep == .identity)

        coord.displayName = "Jose"
        await coord.advanceFromIdentity()
        #expect(coord.currentStep == .group)

        coord.draft.name = "Los Cuates"
        coord.draft.coverImageName = "sunset"
        await coord.advanceFromGroupIdentity()
        #expect(coord.currentStep == .vocabulary)
        #expect(coord.createdGroup != nil)

        coord.draft.eventVocabulary = "cena"
        await coord.advanceFromVocabulary()
        #expect(coord.currentStep == .rules)

        await coord.advanceFromRules()
        #expect(coord.currentStep == .governance)
        // Rules now seed via module activation (mig 00073), not per-draft
        // createInitialRules. Skip the drafts assertion.
        _ = rules

        await coord.advanceFromInvite()
        #expect(coord.currentStep == .phoneVerify)

        coord.phoneE164 = "+5215555551234"
        await coord.advanceFromPhoneVerify()
        #expect(coord.currentStep == .otp)

        otp.verifyResult = .success(())
        await coord.submitOTP(code: "123456")
        #expect(coord.currentStep == .confirm)

        let listed = try await groups.listMine()
        #expect(listed.count == 1)
    }

    // MARK: - Skips

    @Test("skip vocabulary keeps default 'evento'")
    func skipVocabulary() async throws {
        let (coord, _, _, _, _, _) = try makeCoordinator()
        await coord.start()
        await coord.advanceFromWelcome()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.skipVocabulary()
        #expect(coord.currentStep == .rules)
        #expect(coord.draft.eventVocabulary == "evento")
    }

    @Test("skip rules disables basic_fines module")
    func skipRules() async throws {
        let (coord, groups, _, _, _, _) = try makeCoordinator()
        await coord.start()
        await coord.advanceFromWelcome()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.skipVocabulary()
        await coord.skipRules()
        #expect(coord.currentStep == .governance)
        // basic_fines should be archived from active_modules.
        let g = try await groups.listMine().first
        #expect(g?.effectiveActiveModules.contains("basic_fines") == false)
    }

    @Test("skip invite leaves no pending invites")
    func skipInvite() async throws {
        let (coord, _, _, _, _, _) = try makeCoordinator()
        await coord.start()
        await coord.advanceFromWelcome()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.skipVocabulary()
        await coord.skipRules()
        await coord.skipInvite()
        #expect(coord.currentStep == .phoneVerify)
        #expect(coord.pendingInvites.isEmpty)
    }

    // MARK: - Errors

    @Test("create group failure stays on group step + sets error")
    func createGroupFailure() async throws {
        let groups = MockGroupsRepository()
        await groups.setNextCreateError(.rpcFailed("boom"))
        let (coord, _, _, _, _, _) = try makeCoordinator(groupRepo: groups)
        await coord.start()
        await coord.advanceFromWelcome()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        #expect(coord.currentStep == .group) // did NOT advance
        #expect(coord.error != nil)
    }

    @Test("OTP wrong code increments attempts; 3 fails → tooManyAttempts")
    func otpThreeStrikesError() async throws {
        let (coord, _, _, _, otp, _) = try makeCoordinator()
        await coord.start()
        await coord.advanceFromWelcome()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.skipVocabulary()
        await coord.skipRules()
        await coord.skipInvite()
        coord.phoneE164 = "+5215555551234"
        await coord.advanceFromPhoneVerify()
        #expect(coord.currentStep == .otp)

        otp.verifyResult = .failure(.invalidCode)
        await coord.submitOTP(code: "000000")
        #expect(coord.otpAttempts == 1)
        await coord.submitOTP(code: "000000")
        await coord.submitOTP(code: "000000")
        #expect(coord.otpAttempts == 3)
        #expect(coord.error == .otpTooManyAttempts)
        #expect(coord.currentStep == .otp) // did NOT advance to confirm
    }

    // MARK: - Restoration

    @Test("restore from progress entity at step .rules sets currentStep")
    func restoreAtRules() async throws {
        let (coord, _, _, _, _, _) = try makeCoordinator()
        let entity = OnboardingProgress(flowType: .founder)
        entity.founderStep = .rules
        var draft = GroupDraft.empty
        draft.name = "Restored"
        if let data = try? JSONEncoder().encode(draft) {
            entity.draftJSON = data
        }
        entity.displayName = "Restored Name"

        await coord.restore(from: entity)
        #expect(coord.currentStep == .rules)
        #expect(coord.draft.name == "Restored")
        #expect(coord.displayName == "Restored Name")
    }
}

// MARK: - Mock helpers

extension MockGroupsRepository {
    func setNextCreateError(_ err: GroupsError) {
        self.nextCreateError = err
    }
}
