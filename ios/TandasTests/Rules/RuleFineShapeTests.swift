import Foundation
import XCTest
import RuulUI
import RuulCore
@testable import Tandas

/// Tests for `FineConsequenceParser.shape(of:)` — the fine-aware parser
/// that replaced the deprecated `GroupRule.fineShape` extension property
/// per `RulesVsMoneyDoctrine.md` Axioma 1 (Rule ≠ Fine).
final class RuleFineShapeTests: XCTestCase {

    private func rule(
        consequences: [GroupRule.ConsequenceEnvelope]
    ) -> GroupRule {
        GroupRule(
            id: UUID(),
            groupId: UUID(),
            slug: nil,
            name: "Test",
            isActive: true,
            trigger: RuleTrigger(eventType: .checkInRecorded),
            conditions: [],
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

    private func shape(of r: GroupRule) -> FineConsequenceParser.FineShape {
        FineConsequenceParser.shape(of: r.consequences)
    }

    func testFlat() {
        let r = rule(consequences: [fine(amount: 200)])
        XCTAssertEqual(shape(of: r), .flat(amount: 200))
    }

    func testEscalating() {
        let r = rule(consequences: [
            fine(baseAmount: 200, stepAmount: 50, stepMinutes: 30)
        ])
        XCTAssertEqual(shape(of: r), .escalating(base: 200, step: 50, stepMinutes: 30))
    }

    func testEmpty() {
        XCTAssertEqual(shape(of: rule(consequences: [])), .none)
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
        if case .unknown = shape(of: r) { /* ok */ } else {
            XCTFail("expected .unknown for non-flat non-escalating fine config")
        }
    }

    func testMultipleConsequencesUsesFirst() {
        let r = rule(consequences: [
            fine(amount: 100),
            // a non-fine consequence after the fine — should be ignored
            GroupRule.ConsequenceEnvelope(type: "sendNotification", config: nil),
        ])
        XCTAssertEqual(shape(of: r), .flat(amount: 100))
    }

    func testConfigWithExtraFieldsStillFlat() {
        // amount + the escalating fields all present → flat wins (first match)
        let r = rule(consequences: [
            fine(amount: 300, baseAmount: 999, stepAmount: 999, stepMinutes: 999)
        ])
        XCTAssertEqual(shape(of: r), .flat(amount: 300))
    }

    func testFirstAmountMXNFlat() {
        let r = rule(consequences: [fine(amount: 250)])
        XCTAssertEqual(FineConsequenceParser.firstAmountMXN(in: r.consequences), 250)
    }

    func testFirstAmountMXNEscalatingFallsBackToBase() {
        let r = rule(consequences: [
            fine(baseAmount: 100, stepAmount: 50, stepMinutes: 15)
        ])
        XCTAssertEqual(FineConsequenceParser.firstAmountMXN(in: r.consequences), 100)
    }

    func testFirstAmountMXNNonFineReturnsNil() {
        let r = rule(consequences: [
            GroupRule.ConsequenceEnvelope(type: "sendNotification", config: nil)
        ])
        XCTAssertNil(FineConsequenceParser.firstAmountMXN(in: r.consequences))
    }
}
