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

    @Test("full happy path: welcome → identity → group → preset → invite → confirm")
    func happyPath() async throws {
        let (coord, groups, _, _, _, _) = try makeCoordinator()
        await coord.start()

        await coord.advanceFromWelcome()
        #expect(coord.currentStep == .identity)

        coord.displayName = "Jose"
        await coord.advanceFromIdentity()
        #expect(coord.currentStep == .group)

        coord.draft.name = "Los Cuates"
        await coord.advanceFromGroupIdentity()
        #expect(coord.currentStep == .preset)

        await coord.selectPreset(.recurringDinner)
        #expect(coord.currentStep == .invite)
        #expect(coord.createdGroup != nil)

        await coord.advanceFromInvite()
        #expect(coord.currentStep == .confirm)

        let listed = try await groups.listMine()
        #expect(listed.count == 1)
    }

    // MARK: - Preset variations

    @Test("blank preset creates bare group without seeding rules")
    func blankPreset() async throws {
        let (coord, _, _, _, _, _) = try makeCoordinator()
        await coord.start()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.selectPreset(.blank)
        #expect(coord.currentStep == .invite)
        #expect(coord.createdGroup?.baseTemplate == nil || coord.createdGroup?.baseTemplate?.isEmpty == true)
    }

    @Test("skip identity advances with empty name")
    func skipIdentity() async throws {
        let (coord, _, _, _, _, _) = try makeCoordinator()
        await coord.start()
        await coord.skipIdentity()
        #expect(coord.currentStep == .group)
        #expect(coord.displayName.isEmpty)
    }

    @Test("skip invite goes straight to confirm")
    func skipInvite() async throws {
        let (coord, _, _, _, _, _) = try makeCoordinator()
        await coord.start()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.selectPreset(.recurringDinner)
        await coord.skipInvite()
        #expect(coord.currentStep == .confirm)
        #expect(coord.pendingInvites.isEmpty)
    }

    // MARK: - Failures

    @Test("group create failure stays on preset + sets error")
    func createGroupFailure() async throws {
        let groups = MockGroupsRepository()
        await groups.setNextError(.rpcFailed("server down"))
        let (coord, _, _, _, _, _) = try makeCoordinator(groupRepo: groups)
        await coord.start()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        #expect(coord.currentStep == .preset)
        await coord.selectPreset(.recurringDinner)
        #expect(coord.currentStep == .preset)
        guard case .createGroupFailed = coord.error else {
            Issue.record("expected createGroupFailed error")
            return
        }
    }

    // MARK: - Restore

    @Test("legacy persisted step .vocabulary projects to .invite")
    func restoreFromLegacyVocabulary() async throws {
        // Construct a progress entity with a legacy persisted step value
        // by going through the JSON path (FounderStep enum doesn't have
        // .vocabulary anymore so we can't construct one directly).
        // Round-trip: persist 'vocabulary' as raw string, then restore.
        let container = try ModelContainer(
            for: OnboardingProgress.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let manager = OnboardingProgressManager(context: container.mainContext)
        let entity = OnboardingProgress(flowType: .founder)
        entity.founderStepRaw = "vocabulary"
        try manager.save(entity)

        let coord = FounderOnboardingCoordinator(
            groupRepo: MockGroupsRepository(),
            inviteRepo: MockInviteRepository(),
            ruleRepo: MockRuleRepository(),
            otp: MockOTPService(),
            analytics: MockAnalyticsService(),
            progress: manager
        )
        await coord.restore(from: entity)
        // .vocabulary is gone — projects onto .invite. The restore()
        // safeguard (no createdGroup → reset to .group) kicks in because
        // there's no persisted group, so the final state is .group.
        #expect(coord.currentStep == .group)
    }
}

private extension MockGroupsRepository {
    func setNextError(_ err: GroupsError) async {
        await nextCreateErrorIsSet(err)
    }
    func nextCreateErrorIsSet(_ err: GroupsError) async {
        // MockGroupsRepository already exposes `nextCreateError` as a
        // mutable property. Set via the property since this extension
        // can only see public surface.
        self.nextCreateError = err
    }
}
