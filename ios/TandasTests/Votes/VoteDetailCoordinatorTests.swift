import Testing
import Foundation
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("VoteDetailCoordinator")
@MainActor
struct VoteDetailCoordinatorTests {

    // MARK: - Fixtures

    private func makeVote(
        id: UUID = UUID(),
        groupId: UUID = UUID(),
        type: VoteType = .generalProposal,
        status: VoteStatus = .open,
        isAnonymous: Bool = true
    ) -> Vote {
        Vote(
            id: id,
            groupId: groupId,
            voteType: type,
            referenceId: UUID(),
            title: "Test vote",
            description: "Description",
            createdByMemberId: UUID(),
            openedAt: .now,
            closesAt: .now.addingTimeInterval(72 * 3600),
            resolvedAt: status == .resolved ? .now : nil,
            quorumPercent: 50,
            thresholdPercent: 50,
            isAnonymous: isAnonymous,
            status: status,
            counts: nil,
            payload: .empty
        )
    }

    private func makeGroup(id: UUID = UUID()) -> Group {
        Group(
            id: id,
            name: "Cuates",
            inviteCode: "test1234",
            createdBy: UUID(),
            createdAt: .now
        )
    }

    private func makeCoordinator(
        vote: Vote? = nil,
        userMemberId: UUID = UUID(),
        seedCasts: [VoteCast] = []
    ) -> (VoteDetailCoordinator, MockVoteRepository, MockVoteCastRepository) {
        let v = vote ?? makeVote()
        let voteRepo = MockVoteRepository(seed: [v])
        let castRepo = MockVoteCastRepository(seed: seedCasts)
        return (
            VoteDetailCoordinator(
                vote: v,
                group: makeGroup(id: v.groupId),
                userMemberId: userMemberId,
                voteRepo: voteRepo,
                castRepo: castRepo
            ),
            voteRepo,
            castRepo
        )
    }

    // MARK: - Tests

    @Test("refresh fetches myCast and counts in parallel")
    func refreshFetches() async throws {
        let voteId = UUID()
        let memberId = UUID()
        let myCast = VoteCast(
            id: UUID(), voteId: voteId, memberId: memberId,
            choice: .pending, castAt: nil, createdAt: .now, updatedAt: .now
        )
        let v = makeVote(id: voteId)
        let voteRepo = MockVoteRepository(seed: [v])
        let castRepo = MockVoteCastRepository(seed: [myCast])
        let coord = VoteDetailCoordinator(
            vote: v,
            group: makeGroup(id: v.groupId),
            userMemberId: memberId,
            voteRepo: voteRepo,
            castRepo: castRepo
        )

        await coord.refresh()

        #expect(coord.myCast?.id == myCast.id)
        #expect(coord.counts != nil)
        #expect(coord.error == nil)
    }

    @Test("alreadyVoted derives from choice not pending")
    func alreadyVotedDerivation() async throws {
        let voteId = UUID()
        let memberId = UUID()
        let votedCast = VoteCast(
            id: UUID(), voteId: voteId, memberId: memberId,
            choice: .inFavor, castAt: .now, createdAt: .now, updatedAt: .now
        )
        let v = makeVote(id: voteId)
        let coord = VoteDetailCoordinator(
            vote: v,
            group: makeGroup(id: v.groupId),
            userMemberId: memberId,
            voteRepo: MockVoteRepository(seed: [v]),
            castRepo: MockVoteCastRepository(seed: [votedCast])
        )

        await coord.refresh()
        #expect(coord.alreadyVoted == true)
    }

    @Test("voteIsClosed derives from vote status")
    func voteIsClosedDerivation() {
        let resolvedVote = makeVote(status: .resolved)
        let coord = VoteDetailCoordinator(
            vote: resolvedVote,
            group: makeGroup(id: resolvedVote.groupId),
            userMemberId: UUID(),
            voteRepo: MockVoteRepository(),
            castRepo: MockVoteCastRepository()
        )
        #expect(coord.voteIsClosed == true)
    }

    @Test("cast updates myCast and clears error")
    func castFlow() async throws {
        let voteId = UUID()
        let memberId = UUID()
        let pendingCast = VoteCast(
            id: UUID(), voteId: voteId, memberId: memberId,
            choice: .pending, castAt: nil, createdAt: .now, updatedAt: .now
        )
        let v = makeVote(id: voteId)
        let coord = VoteDetailCoordinator(
            vote: v,
            group: makeGroup(id: v.groupId),
            userMemberId: memberId,
            voteRepo: MockVoteRepository(seed: [v]),
            castRepo: MockVoteCastRepository(seed: [pendingCast])
        )

        await coord.refresh()
        #expect(coord.myCast?.choice == .pending)

        await coord.cast(.inFavor)

        #expect(coord.error == nil)
        #expect(coord.isCasting == false)
        #expect(coord.myCast?.choice == .inFavor)
        #expect(coord.alreadyVoted == true)
    }

    @Test("cast surfaces error when RPC throws")
    func castErrorSurfaces() async throws {
        let (coord, _, castRepo) = makeCoordinator()
        await castRepo.setNextCastError(NSError(
            domain: "test", code: 42501,
            userInfo: [NSLocalizedDescriptionKey: "vote is not open"]
        ))
        await coord.cast(.inFavor)
        #expect(coord.error != nil)
        let summary = (coord.error?.title ?? "") + " " + (coord.error?.message ?? "")
        #expect(summary.contains("cerró"))
    }
}
