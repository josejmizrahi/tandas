import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("VoteBlockBuilder")
@MainActor
struct VoteBlockBuilderTests {

    @Test("open vote with viewer not voted → actionable + castVote primary action")
    func openNotVoted() {
        let vote   = TestFixtures.openVoteNotVoted(totalEligible: 8, cast: 3)
        let blocks = VoteBlockBuilder(viewerHasVoted: false).build(
            source: vote,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .actionable)
        #expect(blocks.state.primaryAction?.kind == .castVote)
        #expect(blocks.state.primaryAction?.label.lowercased().contains("vot") == true)
        let tally = blocks.capabilities.first { $0.id == "tally" }
        #expect(tally?.layoutKind == .progress)
        #expect(tally?.isViewerObligation == true)
    }

    @Test("open vote viewer already voted → ambient, no primary action")
    func openAlreadyVoted() {
        let vote   = TestFixtures.openVoteNotVoted(totalEligible: 8, cast: 4)
        let blocks = VoteBlockBuilder(viewerHasVoted: true).build(
            source: vote,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .ambient)
        #expect(blocks.state.primaryAction == nil)
        #expect(blocks.state.headline.lowercased().contains("espera"))
    }

    @Test("closed (resolved) vote renders terminal headline")
    func closedVote() {
        let vote   = TestFixtures.closedVote(totalEligible: 8)
        let blocks = VoteBlockBuilder(viewerHasVoted: true).build(
            source: vote,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        #expect(blocks.state.urgency == .terminal)
        #expect(blocks.state.primaryAction == nil)
    }

    @Test("tally block progress fields use counts from Vote.counts")
    func tallyBlockFields() {
        let vote   = TestFixtures.openVoteNotVoted(totalEligible: 8, cast: 3)
        let blocks = VoteBlockBuilder(viewerHasVoted: false).build(
            source: vote,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        let tally = blocks.capabilities.first { $0.id == "tally" }
        #expect(tally?.payload.progress?.current == 3)
        #expect(tally?.payload.progress?.total == 8)
    }
}
