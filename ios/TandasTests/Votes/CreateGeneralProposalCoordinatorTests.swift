import Testing
import Foundation
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("CreateGeneralProposalCoordinator")
@MainActor
struct CreateGeneralProposalCoordinatorTests {

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
            roles: [.founder, .member],
            active: true,
            joinedAt: .now
        )
    }

    private func makeCoordinator()
    -> (CreateGeneralProposalCoordinator, MockVoteRepository) {
        let group = makeGroup()
        let member = makeMember(groupId: group.id)
        let voteRepo = MockVoteRepository(seed: [])
        let coord = CreateGeneralProposalCoordinator(
            group: group,
            member: member,
            voteRepo: voteRepo,
            governance: GovernanceService()
        )
        return (coord, voteRepo)
    }

    // MARK: - Tests

    @Test("title shorter than min returns invalid")
    func titleMinLength() {
        let (coord, _) = makeCoordinator()
        coord.title = "Hi"
        #expect(coord.canSubmit == false)
    }

    @Test("title longer than max returns invalid")
    func titleMaxLength() {
        let (coord, _) = makeCoordinator()
        coord.title = String(repeating: "x", count: 101)
        #expect(coord.canSubmit == false)
    }

    @Test("title in range = canSubmit true")
    func canSubmitHappy() {
        let (coord, _) = makeCoordinator()
        coord.title = "Cambio razonable"
        #expect(coord.canSubmit == true)
    }

    @Test("submit calls startVote with correct vote_type")
    func submitWiresStartVote() async throws {
        let (coord, voteRepo) = makeCoordinator()
        coord.title = "Vote please"
        coord.description = "Reason"

        await coord.submit()

        #expect(coord.error == nil)
        let calls = await voteRepo.startVoteCalls
        #expect(calls.count == 1)
        #expect(calls.first?.voteType == .generalProposal)
        #expect(calls.first?.title == "Vote please")
    }

    @Test("submit error surfaces user-facing message")
    func submitErrorSurfaces() async throws {
        let (coord, voteRepo) = makeCoordinator()
        await voteRepo.setNextStartError(NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "rpc 500"]
        ))
        coord.title = "Vote please"
        await coord.submit()

        #expect(coord.error != nil)
        #expect(coord.error?.contains("500") == true)
    }
}
