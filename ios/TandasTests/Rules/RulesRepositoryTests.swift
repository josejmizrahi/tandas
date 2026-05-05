import Foundation
import XCTest
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
            code: nil,
            title: "Tarde a evento",
            description: nil,
            enabled: true,
            isActive: true,
            action: nil,
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

    func testSetEnabledHappyPath() async throws {
        let mock = MockRuleRepository()
        let ruleId = UUID()
        try await mock.setEnabled(ruleId: ruleId, enabled: false)
        let last = await mock.lastSetEnabled
        XCTAssertEqual(last?.ruleId, ruleId)
        XCTAssertEqual(last?.enabled, false)
    }
}
