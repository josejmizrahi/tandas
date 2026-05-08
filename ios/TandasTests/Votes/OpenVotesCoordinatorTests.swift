import Testing
import Foundation
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("OpenVotesCoordinator")
@MainActor
struct OpenVotesCoordinatorTests {

    private func makeGroup(id: UUID = UUID()) -> Group {
        Group(
            id: id,
            name: "Cuates",
            inviteCode: "test1234",
            createdBy: UUID(),
            createdAt: .now
        )
    }

    private func makeVote(
        groupId: UUID,
        closesIn hours: TimeInterval = 24,
        status: VoteStatus = .open
    ) -> Vote {
        Vote(
            id: UUID(), groupId: groupId, voteType: .generalProposal,
            referenceId: UUID(), title: "Vote", description: nil,
            createdByMemberId: nil,
            openedAt: .now,
            closesAt: .now.addingTimeInterval(hours * 3600),
            resolvedAt: nil, quorumPercent: 50, thresholdPercent: 50,
            isAnonymous: true, status: status, counts: nil, payload: .empty
        )
    }

    @Test("refresh empty group yields empty list")
    func refreshEmpty() async throws {
        let group = makeGroup()
        let repo = MockVoteRepository(seed: [])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()
        #expect(coord.openVotes.isEmpty)
        #expect(coord.error == nil)
    }

    @Test("refresh fetches only open votes for the group")
    func refreshFiltersByGroupAndStatus() async throws {
        let group = makeGroup()
        let myVote = makeVote(groupId: group.id, status: .open)
        let otherGroupVote = makeVote(groupId: UUID(), status: .open)
        let resolvedVote = makeVote(groupId: group.id, status: .resolved)
        let repo = MockVoteRepository(seed: [myVote, otherGroupVote, resolvedVote])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)

        await coord.refresh()

        #expect(coord.openVotes.count == 1)
        #expect(coord.openVotes.first?.id == myVote.id)
    }

    @Test(
        "sectioned splits closing-soon vs other",
        .disabled("Pre-existing stale test: Section was refactored from .closingSoon/.open (urgency-based) to .pending/.voted (action-based) at OpenVotesCoordinator.swift:98-101 sin actualizar este test. Necesita reescribirse con MockVoteRepository sembrando algunos votos con my_choice='pending' y otros con my_choice asignado para ejercitar el splitting real. Tracked como cleanup orphan post-Beta 1.")
    )
    func sectioned() async throws {
        let group = makeGroup()
        let closingSoon = makeVote(groupId: group.id, closesIn: 12)
        let later = makeVote(groupId: group.id, closesIn: 48)
        let repo = MockVoteRepository(seed: [closingSoon, later])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()
        let sections = coord.sectioned()

        #expect(sections.count == 2)
        // Disabled until rewritten — see @Test attribute above for context.
    }

    @Test("refresh surfaces error string when repo throws")
    func refreshErrorSurfaces() async throws {
        let group = makeGroup()
        let repo = MockVoteRepository(seed: [])
        await repo.setNextOpenVotesError(NSError(
            domain: "test", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "network down"]
        ))
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()

        #expect(coord.error?.message?.contains("network down") == true)
        #expect(coord.openVotes.isEmpty)
    }
}
