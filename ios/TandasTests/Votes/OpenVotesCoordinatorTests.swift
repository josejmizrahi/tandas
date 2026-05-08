import Testing
import Foundation
import RuulUI
import RuulCore
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

    @Test("sectioned splits closing-soon vs other")
    func sectioned() async throws {
        let group = makeGroup()
        let closingSoon = makeVote(groupId: group.id, closesIn: 12)   // <24h
        let later = makeVote(groupId: group.id, closesIn: 48)         // ≥24h
        let repo = MockVoteRepository(seed: [closingSoon, later])
        let coord = OpenVotesCoordinator(group: group, voteRepo: repo)
        await coord.refresh()
        let sections = coord.sectioned()

        #expect(sections.count == 2)
        let closingSoonSection = sections.first { $0.0 == .closingSoon }
        let openSection = sections.first { $0.0 == .open }
        #expect(closingSoonSection?.1.count == 1)
        #expect(openSection?.1.count == 1)
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
