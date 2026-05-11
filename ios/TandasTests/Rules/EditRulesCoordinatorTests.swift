import Foundation
import XCTest
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@MainActor
final class EditRulesCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        policyDecision: PolicyDecision = .adminOnly
    ) async -> EditRulesCoordinator {
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .founder, groupId: group.id)
        let governance = MockGovernanceService(nextDecision: .allowed)
        let policyRepo = MockGroupPolicyRepository()
        await policyRepo.setResolution(
            groupId: group.id, action: .ruleToggle, decision: policyDecision
        )
        let ruleRepo = MockRuleRepository()
        let voteRepo = MockVoteRepository()
        return EditRulesCoordinator(
            group: group,
            currentMember: member,
            actorUserId: member.userId,
            governance: governance,
            policyRepo: policyRepo,
            ruleRepo: ruleRepo,
            voteRepo: voteRepo
        )
    }

    func testEditModeDefaultsToReadOnlyBeforeRefresh() async {
        let c = await makeCoordinator()
        XCTAssertEqual(c.editMode, .readOnly)
        XCTAssertFalse(c.canEditRules)
    }

    func testRefreshAllowedSetsDirectWriteMode() async {
        let c = await makeCoordinator(policyDecision: .allowed)
        await c.refresh()
        XCTAssertEqual(c.editMode, .directWrite)
        XCTAssertTrue(c.canEditRules)
    }

    func testRefreshVoteRequiredSetsVoteGatedMode() async {
        let c = await makeCoordinator(
            policyDecision: .voteRequired(quorumPercent: 50, thresholdPercent: 66, durationHours: 72)
        )
        await c.refresh()
        XCTAssertEqual(c.editMode, .voteGated(thresholdPercent: 66))
        // canEditRules is true in voteGated mode — user CAN propose, just
        // not write directly.
        XCTAssertTrue(c.canEditRules)
    }

    func testRefreshAdminOnlyDecisionKeepsReadOnly() async {
        let c = await makeCoordinator(policyDecision: .adminOnly)
        await c.refresh()
        XCTAssertEqual(c.editMode, .readOnly)
        XCTAssertFalse(c.canEditRules)
    }

    func testRefreshDeniedDecisionKeepsReadOnly() async {
        let c = await makeCoordinator(policyDecision: .denied(reason: "not_member"))
        await c.refresh()
        XCTAssertEqual(c.editMode, .readOnly)
        XCTAssertFalse(c.canEditRules)
    }
}

// MARK: - Test fixtures

/// Mock `GovernanceServiceProtocol` retained for backwards compat with the
/// coordinator's `governance` dependency (used by future fine-grained
/// actions). The current voteGated test relies on PolicyDecision, not on
/// GovernanceDecision.
final class MockGovernanceService: GovernanceServiceProtocol, @unchecked Sendable {
    var nextDecision: GovernanceDecision
    var throwOnNext: Bool

    init(nextDecision: GovernanceDecision, throwOnNext: Bool = false) {
        self.nextDecision = nextDecision
        self.throwOnNext = throwOnNext
    }

    func canPerform(
        _ action: GovernanceAction,
        member: Member,
        in group: Group,
        context: GovernanceContext?
    ) async throws -> GovernanceDecision {
        if throwOnNext { throw NSError(domain: "mock.governance", code: 1) }
        return nextDecision
    }
}

private extension Group {
    /// Minimal `Group` fixture for coordinator tests.
    static func mock(id: UUID) -> Group {
        Group(
            id: id,
            name: "Test Group",
            inviteCode: "test1234",
            createdBy: UUID(),
            createdAt: .now
        )
    }
}

private extension Member {
    /// Minimal `Member` fixture for coordinator tests.
    static func mock(role: MemberRole, groupId: UUID = UUID()) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: UUID(),
            role: role == .founder ? "admin" : "member",
            roles: [role],
            joinedAt: .now
        )
    }
}
