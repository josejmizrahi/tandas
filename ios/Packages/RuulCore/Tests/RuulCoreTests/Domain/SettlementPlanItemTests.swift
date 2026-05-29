import Foundation
import Testing
@testable import RuulCore

@Suite("SettlementPlanItem")
struct SettlementPlanItemTests {

    @Test("positive netAmount means caller owes the counterparty")
    func directionYouOwe() {
        let item = SettlementPlanItem(
            counterpartyMembershipId: UUID(),
            counterpartyDisplayName: "Pedro",
            netAmount: Decimal(string: "50")!,
            unit: "MXN"
        )
        #expect(item.direction == .youOwe)
        #expect(item.absoluteAmount == Decimal(string: "50"))
    }

    @Test("negative netAmount means counterparty owes the caller")
    func directionTheyOwe() {
        let item = SettlementPlanItem(
            counterpartyMembershipId: UUID(),
            counterpartyDisplayName: "María",
            netAmount: Decimal(string: "-30")!,
            unit: "MXN"
        )
        #expect(item.direction == .theyOwe)
        #expect(item.absoluteAmount == Decimal(string: "30"))
    }
}
