import Foundation
import XCTest
@testable import Tandas

final class RuleFineShapeTests: XCTestCase {

    private func rule(
        consequences: [GroupRule.ConsequenceEnvelope]
    ) -> GroupRule {
        GroupRule(
            id: UUID(),
            groupId: UUID(),
            code: nil,
            title: "Test",
            description: nil,
            enabled: true,
            isActive: true,
            action: nil,
            consequences: consequences
        )
    }

    private func fine(
        amount: Int? = nil,
        baseAmount: Int? = nil,
        stepAmount: Int? = nil,
        stepMinutes: Int? = nil
    ) -> GroupRule.ConsequenceEnvelope {
        GroupRule.ConsequenceEnvelope(
            type: "fine",
            config: GroupRule.ConsequenceEnvelope.Config(
                amount: amount,
                baseAmount: baseAmount,
                stepAmount: stepAmount,
                stepMinutes: stepMinutes
            )
        )
    }

    func testFlat() {
        let r = rule(consequences: [fine(amount: 200)])
        XCTAssertEqual(r.fineShape, .flat(amount: 200))
    }

    func testEscalating() {
        let r = rule(consequences: [
            fine(baseAmount: 200, stepAmount: 50, stepMinutes: 30)
        ])
        XCTAssertEqual(r.fineShape, .escalating(base: 200, step: 50, stepMinutes: 30))
    }

    func testEmpty() {
        XCTAssertEqual(rule(consequences: []).fineShape, .none)
    }

    func testUnknown() {
        // fine consequence with no recognised numeric fields → unknown
        let r = rule(consequences: [
            GroupRule.ConsequenceEnvelope(
                type: "fine",
                config: GroupRule.ConsequenceEnvelope.Config(
                    amount: nil,
                    baseAmount: nil,
                    stepAmount: nil,
                    stepMinutes: nil
                )
            )
        ])
        if case .unknown = r.fineShape { /* ok */ } else {
            XCTFail("expected .unknown for non-flat non-escalating fine config")
        }
    }

    func testMultipleConsequencesUsesFirst() {
        let r = rule(consequences: [
            fine(amount: 100),
            // a non-fine consequence after the fine — should be ignored
            GroupRule.ConsequenceEnvelope(type: "sendNotification", config: nil),
        ])
        XCTAssertEqual(r.fineShape, .flat(amount: 100))
    }

    func testConfigWithExtraFieldsStillFlat() {
        // amount + the escalating fields all present → flat wins (first match)
        let r = rule(consequences: [
            fine(amount: 300, baseAmount: 999, stepAmount: 999, stepMinutes: 999)
        ])
        XCTAssertEqual(r.fineShape, .flat(amount: 300))
    }
}
