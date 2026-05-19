import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("FundBlockBuilder")
@MainActor
struct FundBlockBuilderTests {

    @Test("active fund with balance renders balance layout + ambient urgency")
    func activeFund() {
        let builder = FundBlockBuilder()
        let source  = TestFixtures.activeFundRow(balanceCents: 430_000)
        let viewer  = TestFixtures.guestViewerContext()
        let blocks  = builder.build(source: source, viewer: viewer, now: TestFixtures.now)

        #expect(blocks.state.urgency == .ambient)
        let balanceBlock = blocks.capabilities.first { $0.id == "balance" }
        #expect(balanceBlock != nil)
        #expect(balanceBlock?.layoutKind == .balance)
        #expect(blocks.state.primaryAction?.kind == .openContribute)
    }

    @Test("locked fund headline says bloqueado + no primary action")
    func lockedFund() {
        let builder = FundBlockBuilder()
        let source  = TestFixtures.lockedFundRow()
        let blocks  = builder.build(
            source: source,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        #expect(blocks.state.headline.lowercased().contains("bloque"))
        #expect(blocks.state.primaryAction == nil)
        #expect(blocks.state.urgency == .terminal)
    }

    @Test("fund with no balance_cents renders fallback dash")
    func fundNoBalance() {
        let source = TestFixtures.activeFundRow(balanceCents: nil)
        let blocks = FundBlockBuilder().build(
            source: source,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        let balanceBlock = blocks.capabilities.first { $0.id == "balance" }
        #expect(balanceBlock?.payload.balance?.primary == "—")
    }
}
