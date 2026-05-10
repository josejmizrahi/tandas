import Foundation
import XCTest
import RuulUI
import RuulCore
@testable import Tandas

@MainActor
final class RulesRepositoryTests: XCTestCase {
    func testSetFlatFineAmountRejectsEscalatingShape() async throws {
        let escalatingConfig = GroupRule.ConsequenceEnvelope.Config(
            amount: nil,
            baseAmount: 200,
            stepAmount: 50,
            stepMinutes: 30
        )
        let escalating = GroupRule.ConsequenceEnvelope(type: "fine", config: escalatingConfig)
        let escalatingRule = GroupRule(
            id: UUID(),
            groupId: UUID(),
            slug: nil,
            name: "Tarde a evento",
            isActive: true,
            trigger: RuleTrigger(eventType: .checkInRecorded),
            conditions: [],
            consequences: [escalating]
        )

        let mock = MockRuleRepository()
        do {
            try await mock.setFlatFineAmount(rule: escalatingRule, amount: 999)
            XCTFail("expected RulesRepositoryError.notFlatFine")
        } catch RulesRepositoryError.notFlatFine {
            // success
        } catch {
            XCTFail("expected notFlatFine, got \(error)")
        }
    }

    func testSetIsActiveHappyPath() async throws {
        let mock = MockRuleRepository()
        let ruleId = UUID()
        try await mock.setIsActive(ruleId: ruleId, isActive: false)
        let last = await mock.lastSetIsActive
        XCTAssertEqual(last?.ruleId, ruleId)
        XCTAssertEqual(last?.isActive, false)
    }
}
