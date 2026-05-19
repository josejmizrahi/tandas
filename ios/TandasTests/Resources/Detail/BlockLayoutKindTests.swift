import Testing
import RuulCore

@Suite("BlockLayoutKind")
struct BlockLayoutKindTests {
    @Test("has exactly seven cases")
    func sevenCases() {
        let all = BlockLayoutKind.allCases
        #expect(all.count == 7)
    }

    @Test("contains the seven canonical layouts")
    func canonicalLayouts() {
        let all = Set(BlockLayoutKind.allCases)
        #expect(all == [
            .summaryFacts, .avatarQueue, .mediaStrip,
            .balance, .progress, .timelineMini, .emptyPrompt
        ])
    }
}
