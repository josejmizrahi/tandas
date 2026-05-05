import Foundation
import XCTest
@testable import Tandas

@MainActor
final class EditRulesCoordinatorTests: XCTestCase {
    private func makeCoordinator(decision: GovernanceDecision = .allowed,
                                 throwOnNext: Bool = false) -> EditRulesCoordinator {
        let group = Group.mock(id: UUID())
        let member = Member.mock(role: .founder, groupId: group.id)
        let governance = MockGovernanceService(nextDecision: decision, throwOnNext: throwOnNext)
        let ruleRepo = MockRuleRepository()
        let voteRepo = MockVoteRepository()
        return EditRulesCoordinator(
            group: group,
            currentMember: member,
            governance: governance,
            ruleRepo: ruleRepo,
            voteRepo: voteRepo
        )
    }

    func testCanEditDefaultsFalse() {
        XCTAssertFalse(makeCoordinator().canEditRules)
    }

    func testRefreshAllowedSetsCanEditTrue() async {
        let c = makeCoordinator(decision: .allowed)
        await c.refresh()
        XCTAssertTrue(c.canEditRules)
    }

    func testRefreshRequiresVoteIsTreatedAsDenied() async {
        let c = makeCoordinator(decision: .requiresVote(quorumPercent: 50, thresholdPercent: 50))
        await c.refresh()
        XCTAssertFalse(c.canEditRules)
    }

    func testRefreshDeniedKeepsCanEditFalse() async {
        let c = makeCoordinator(decision: .denied(reason: .notFounder))
        await c.refresh()
        XCTAssertFalse(c.canEditRules)
    }

    func testRefreshGovernanceThrowFailsClosed() async {
        let c = makeCoordinator(decision: .allowed, throwOnNext: true)
        await c.refresh()
        XCTAssertFalse(c.canEditRules)
    }
}

// MARK: - Test fixtures

/// Mock `GovernanceServiceProtocol` that returns a configured decision (or
/// throws). Used by the coordinator tests above to exercise the
/// `canEditRules` state machine without spinning up the real actor.
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
    /// Minimal `Group` fixture for coordinator tests. Defaults match
    /// `recurring_dinner` so `effectiveGovernance` evaluates as expected.
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
    /// Minimal `Member` fixture for coordinator tests. The single-role
    /// override drives both `role` text and `roles` array, which is what
    /// `GovernanceService` reads.
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
