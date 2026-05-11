import Foundation
import XCTest
import RuulCore

final class RuleRepositoryInterceptionTests: XCTestCase {

    func testToggleOpensVoteWhenPolicyRequiresVote() async throws {
        let groupId = UUID()
        let ruleId  = UUID()
        let actorId = UUID()

        let policyRepo = MockGroupPolicyRepository()
        await policyRepo.setResolution(
            groupId: groupId,
            action: .ruleToggle,
            decision: .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)
        )
        let voteRepo = MockVoteRepository()
        let inner    = MockRuleRepository()
        let repo = InterceptingRuleRepository(
            inner: inner,
            policyRepo: policyRepo,
            voteRepo: voteRepo,
            actorUserId: actorId
        )

        let outcome = try await repo.setIsActive(
            ruleId: ruleId,
            isActive: false,
            groupId: groupId,
            currentIsActive: true
        )

        switch outcome {
        case .vote(let voteId):
            XCTAssertNotEqual(voteId, UUID())
        default:
            XCTFail("expected .vote outcome, got \(outcome)")
        }

        let calls = await voteRepo.startVoteCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.voteType, .ruleChange)
        XCTAssertEqual(calls.first?.referenceId, ruleId)

        let lastDirect = await inner.lastSetIsActive
        XCTAssertNil(lastDirect, "inner repo must not be touched when vote is opened")
    }

    func testToggleAppliesDirectlyWhenAllowed() async throws {
        let groupId = UUID()
        let ruleId  = UUID()
        let actorId = UUID()

        let policyRepo = MockGroupPolicyRepository()
        await policyRepo.setResolution(groupId: groupId, action: .ruleToggle, decision: .allowed)

        let voteRepo = MockVoteRepository()
        let inner    = MockRuleRepository()
        let repo = InterceptingRuleRepository(
            inner: inner,
            policyRepo: policyRepo,
            voteRepo: voteRepo,
            actorUserId: actorId
        )

        let outcome = try await repo.setIsActive(
            ruleId: ruleId, isActive: false, groupId: groupId, currentIsActive: true
        )

        XCTAssertEqual(outcome, .applied)
        let last = await inner.lastSetIsActive
        XCTAssertEqual(last?.ruleId, ruleId)
        XCTAssertEqual(last?.isActive, false)

        let voteCalls = await voteRepo.startVoteCalls
        XCTAssertTrue(voteCalls.isEmpty, "no vote should open when policy allows direct")
    }

    func testToggleReturnsAdminOnlyOutcomeWhenPolicySaysAdminOnly() async throws {
        let groupId = UUID()
        let actorId = UUID()
        let policyRepo = MockGroupPolicyRepository()
        await policyRepo.setResolution(groupId: groupId, action: .ruleToggle, decision: .adminOnly)

        let inner = MockRuleRepository()
        let repo = InterceptingRuleRepository(
            inner: inner,
            policyRepo: policyRepo,
            voteRepo: MockVoteRepository(),
            actorUserId: actorId
        )

        let outcome = try await repo.setIsActive(
            ruleId: UUID(), isActive: false, groupId: groupId, currentIsActive: true
        )
        XCTAssertEqual(outcome, .adminOnly)
        let last = await inner.lastSetIsActive
        XCTAssertNil(last, "inner repo must not be touched on admin_only")
    }

    func testToggleThrowsWhenDenied() async throws {
        let groupId = UUID()
        let policyRepo = MockGroupPolicyRepository()
        await policyRepo.setResolution(
            groupId: groupId,
            action: .ruleToggle,
            decision: .denied(reason: "not_member")
        )

        let repo = InterceptingRuleRepository(
            inner: MockRuleRepository(),
            policyRepo: policyRepo,
            voteRepo: MockVoteRepository(),
            actorUserId: UUID()
        )

        do {
            _ = try await repo.setIsActive(
                ruleId: UUID(), isActive: false, groupId: groupId, currentIsActive: true
            )
            XCTFail("expected setIsActive to throw")
        } catch RuleMutationError.denied(let reason) {
            XCTAssertEqual(reason, "not_member")
        }
    }

    func testVoteEnvelopeCarriesBeforeAndAfter() async throws {
        let groupId = UUID()
        let ruleId  = UUID()
        let actorId = UUID()

        let policyRepo = MockGroupPolicyRepository()
        await policyRepo.setResolution(
            groupId: groupId,
            action: .ruleToggle,
            decision: .voteRequired(quorumPercent: 50, thresholdPercent: 50, durationHours: 72)
        )
        let voteRepo = MockVoteRepository()
        let repo = InterceptingRuleRepository(
            inner: MockRuleRepository(),
            policyRepo: policyRepo,
            voteRepo: voteRepo,
            actorUserId: actorId
        )

        _ = try await repo.setIsActive(
            ruleId: ruleId, isActive: false, groupId: groupId, currentIsActive: true
        )

        let call = (await voteRepo.startVoteCalls).first!
        // Round-trip the persisted JSONConfig payload back into the typed
        // envelope to verify the wire shape the server will read.
        let data = try JSONEncoder().encode(call.payload)
        let env = try JSONDecoder().decode(PendingChangeEnvelope.self, from: data)
        XCTAssertEqual(env.op, .ruleToggle)
        XCTAssertEqual(env.targetRuleId, ruleId)
        if case .toggle(let after) = env.after.inner {
            XCTAssertEqual(after.isActive, false)
        } else {
            XCTFail("expected after to be toggle body")
        }
    }
}
