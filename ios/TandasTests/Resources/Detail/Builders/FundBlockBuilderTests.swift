import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("FundBlockBuilder")
@MainActor
struct FundBlockBuilderTests {

    @Test("active fund: amount is the hero headline + ambient urgency + openContribute")
    func activeFund() {
        let builder = FundBlockBuilder()
        let source  = TestFixtures.activeFundRow(balanceCents: 430_000)
        let viewer  = TestFixtures.guestViewerContext()
        let blocks  = builder.build(source: source, viewer: viewer, now: TestFixtures.now)

        #expect(blocks.state.urgency == .ambient)
        // Apple-Wallet redesign (founder review 2026-05-21): the amount
        // lives in the StateHero headline; the separate `balance`
        // CapabilityBlock was dropped, so capabilities is empty.
        #expect(blocks.state.headline.contains("4,300"))
        #expect(blocks.capabilities.isEmpty)
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

    @Test("fund with no balance_cents renders the calm empty-state headline")
    func fundNoBalance() {
        let source = TestFixtures.activeFundRow(balanceCents: nil)
        let blocks = FundBlockBuilder().build(
            source: source,
            viewer: TestFixtures.guestViewerContext(),
            now: TestFixtures.now
        )
        // Unknown balance → the hero is a calm prompt rather than a
        // broken "Saldo —"; no separate balance card is produced.
        #expect(blocks.state.headline == "Aún sin movimientos")
        #expect(blocks.capabilities.isEmpty)
    }
}
