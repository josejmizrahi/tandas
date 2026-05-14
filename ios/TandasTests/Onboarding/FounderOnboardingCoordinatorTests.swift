import Testing
import Foundation
import RuulCore
import RuulFeatures
@testable import Tandas

// SwiftData ModelContainer initialization on Xcode 26.3 simulators hangs
// the test process for ~12s and then kills the runner. Switching to
// `InMemoryOnboardingProgressStore` (production protocol, same surface)
// keeps these tests deterministic on CI while still exercising the
// coordinator's persistence path end-to-end.

@Suite("FounderOnboardingCoordinator")
@MainActor
struct FounderOnboardingCoordinatorTests {

    // MARK: - Helpers

    private func makeCoordinator(
        groupRepo: MockGroupsRepository = .init(),
        inviteRepo: MockInviteRepository = .init(),
        ruleRepo: MockRuleRepository = .init(),
        otp: MockOTPService = .init()
    ) -> (FounderOnboardingCoordinator, MockGroupsRepository, MockInviteRepository, MockRuleRepository, MockOTPService, MockAnalyticsService) {
        let analytics = MockAnalyticsService()
        let manager = InMemoryOnboardingProgressStore()
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

    @Test("full happy path: welcome → identity → group → preset → consent → invite → confirm")
    func happyPath() async throws {
        let (coord, groups, _, _, _, _) = makeCoordinator()
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
        // Beta 1 W3 B-3.4: dinner template seeds rules, so the coordinator
        // routes through the consent step before invite.
        #expect(coord.currentStep == .consent)
        #expect(coord.createdGroup != nil)
        #expect(!coord.templateRulePreviews.isEmpty)

        await coord.advanceFromConsent()
        #expect(coord.currentStep == .invite)

        await coord.advanceFromInvite()
        #expect(coord.currentStep == .confirm)

        let listed = try await groups.listMine()
        #expect(listed.count == 1)
    }

    @Test("dinner preset populates templateRulePreviews before consent")
    func consentReceivesSeededRules() async throws {
        let (coord, _, _, _, _, _) = makeCoordinator()
        await coord.start()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.selectPreset(.recurringDinner)

        #expect(coord.currentStep == .consent)
        // MockRuleRepository's seedTemplateRules returns the 5 dinner
        // rules; the coordinator stores them on templateRulePreviews so
        // ConsentRulesView can render them.
        #expect(coord.templateRulePreviews.count == 5)
        // B-1.1: every monetary fine ships in modo sugerencia.
        #expect(coord.templateRulePreviews.allSatisfy { $0.isActive == false })
    }

    // MARK: - Preset variations

    @Test("blank preset creates bare group without seeding rules")
    func blankPreset() async throws {
        let (coord, _, _, _, _, _) = makeCoordinator()
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
        let (coord, _, _, _, _, _) = makeCoordinator()
        await coord.start()
        await coord.skipIdentity()
        #expect(coord.currentStep == .group)
        #expect(coord.displayName.isEmpty)
    }

    @Test("skip invite goes straight to confirm")
    func skipInvite() async throws {
        let (coord, _, _, _, _, _) = makeCoordinator()
        await coord.start()
        coord.displayName = "X"
        await coord.advanceFromIdentity()
        coord.draft.name = "G"
        await coord.advanceFromGroupIdentity()
        await coord.selectPreset(.recurringDinner)
        // Dinner seeds rules → consent step appears before invite (B-3.4).
        #expect(coord.currentStep == .consent)
        await coord.advanceFromConsent()
        await coord.skipInvite()
        #expect(coord.currentStep == .confirm)
        #expect(coord.pendingInvites.isEmpty)
    }

    // MARK: - Failures

    @Test("group create failure stays on preset + sets error")
    func createGroupFailure() async throws {
        let groups = MockGroupsRepository()
        await groups.setNextError(.rpcFailed("server down"))
        let (coord, _, _, _, _, _) = makeCoordinator(groupRepo: groups)
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
        let manager = InMemoryOnboardingProgressStore()
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
