import Testing
import Foundation
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("CreateRuleChangeCoordinator")
@MainActor
struct CreateRuleChangeCoordinatorTests {

    // MARK: - Fixtures

    private func makeGroup(id: UUID = UUID()) -> Group {
        Group(
            id: id,
            name: "Cuates",
            inviteCode: "test1234",
            createdBy: UUID(),
            createdAt: .now
        )
    }

    private func makeMember(groupId: UUID = UUID()) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: UUID(),
            displayNameOverride: nil,
            role: "admin",
            roles: [.founder, .member],
            active: true,
            joinedAt: .now
        )
    }

    private func makeRule(currentAmount: Int = 200) -> GroupRule {
        GroupRule(
            id: UUID(),
            groupId: UUID(),
            slug: nil,
            name: "Llegar tarde",
            isActive: true,
            trigger: RuleTrigger(eventType: .checkInRecorded),
            conditions: [],
            consequences: [
                GroupRule.ConsequenceEnvelope(
                    type: "fine",
                    config: GroupRule.ConsequenceEnvelope.Config(
                        amount: currentAmount,
                        baseAmount: nil,
                        stepAmount: nil,
                        stepMinutes: nil
                    )
                )
            ]
        )
    }

    // MARK: - Tests

    @Test("rule selection required to submit")
    func rulePickerRequired() {
        let voteRepo = MockVoteRepository()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [makeRule()], voteRepo: voteRepo,
            governance: GovernanceService()
        )
        coord.proposedAmount = 250
        coord.reason = "Razón válida más de 5 chars"
        #expect(coord.canSubmit == false)
    }

    @Test("proposed amount must be positive")
    func amountPositive() {
        let rule = makeRule()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [rule],
            voteRepo: MockVoteRepository(),
            governance: GovernanceService()
        )
        coord.selectedRule = rule
        coord.proposedAmount = 0
        coord.reason = "Razón válida"
        #expect(coord.canSubmit == false)
    }

    @Test("submit composes payload with current and proposed")
    func payloadComposition() async throws {
        let rule = makeRule(currentAmount: 200)
        let voteRepo = MockVoteRepository()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [rule],
            voteRepo: voteRepo, governance: GovernanceService()
        )
        coord.selectedRule = rule
        coord.proposedAmount = 350
        coord.reason = "Cambio razonable"

        await coord.submit()

        let calls = await voteRepo.startVoteCalls
        #expect(calls.count == 1)
        #expect(calls.first?.voteType == .ruleChange)
        #expect(calls.first?.referenceId == rule.id)

        guard case .object(let payload) = calls.first?.payload else {
            Issue.record("payload should be object")
            return
        }
        guard case .int(let proposed) = payload["proposed_amount"] else {
            Issue.record("proposed_amount missing")
            return
        }
        #expect(proposed == 350)
    }

    @Test("submit wires startVote with rule_change type and rule_id as reference")
    func submitWires() async throws {
        let rule = makeRule()
        let voteRepo = MockVoteRepository()
        let coord = CreateRuleChangeCoordinator(
            group: makeGroup(), member: makeMember(),
            availableRules: [rule],
            voteRepo: voteRepo, governance: GovernanceService()
        )
        coord.selectedRule = rule
        coord.proposedAmount = 350
        coord.reason = "Razón válida"

        await coord.submit()

        let call = try #require(await voteRepo.startVoteCalls.first)
        #expect(call.voteType == .ruleChange)
        #expect(call.referenceId == rule.id)
    }
}
