import Testing
import Foundation
import RuulCore

@Suite("BlockPriorityResolver")
struct BlockPriorityResolverTests {
    private let neutralPayload = CapabilityBlock.Payload(facts: [])

    private func block(_ id: String, obligation: Bool = false, empty: Bool = false) -> CapabilityBlock {
        CapabilityBlock(
            id: id, title: id, icon: "circle",
            layoutKind: empty ? .emptyPrompt : .summaryFacts,
            payload: neutralPayload, isViewerObligation: obligation
        )
    }

    @Test("an obligation block jumps to first position")
    func obligationFirst() {
        let blocks = [
            block("ledger"),
            block("rotation"),
            block("rsvp", obligation: true)
        ]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.first?.id == "rsvp")
    }

    @Test("empty prompts sink to the end")
    func emptyPromptsLast() {
        let blocks = [
            block("ledger", empty: true),
            block("rotation"),
            block("rsvp")
        ]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.last?.id == "ledger")
    }

    @Test("stable order among same-bucket blocks (preserves builder order)")
    func stableInBucket() {
        let blocks = [block("a"), block("b"), block("c")]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.map(\.id) == ["a", "b", "c"])
    }

    @Test("multiple obligations preserve their relative order")
    func multipleObligations() {
        let blocks = [
            block("rsvp", obligation: true),
            block("rotation"),
            block("vote", obligation: true)
        ]
        let ordered = BlockPriorityResolver.order(blocks)
        #expect(ordered.prefix(2).map(\.id) == ["rsvp", "vote"])
    }
}
