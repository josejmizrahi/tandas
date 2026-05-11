import Foundation
import XCTest
import RuulCore

final class GroupPolicyPresetsTests: XCTestCase {

    func testCasualPresetUsesAdminOnlyForAllRuleActions() {
        let preset = GroupPolicyPreset.casual
        XCTAssertEqual(preset.specs.count, TargetAction.allCases.count)
        for spec in preset.specs {
            XCTAssertEqual(spec.policyType, .adminOnly, "casual preset must be admin_only for \(spec.action)")
            XCTAssertNil(spec.approvalConfig, "casual preset has no approval_config")
        }
    }

    func testBalancedPresetUsesVoteForCostImpactingActions() {
        let preset = GroupPolicyPreset.balanced
        let toggle = preset.specs.first { $0.action == .ruleToggle }!
        let create = preset.specs.first { $0.action == .ruleCreate }!
        let update = preset.specs.first { $0.action == .ruleUpdateAmount }!
        let delete = preset.specs.first { $0.action == .ruleDelete }!

        XCTAssertEqual(toggle.policyType, .adminOnly)
        XCTAssertEqual(create.policyType, .adminOnly)

        XCTAssertEqual(update.policyType, .voteRequired)
        XCTAssertEqual(update.approvalConfig?.quorumPercent, 50)
        XCTAssertEqual(update.approvalConfig?.thresholdPercent, 50)
        XCTAssertEqual(update.approvalConfig?.durationHours, 72)

        XCTAssertEqual(delete.policyType, .voteRequired)
    }

    func testStrictPresetUsesSupermajorityForDestructiveActions() {
        let preset = GroupPolicyPreset.strict
        let toggle = preset.specs.first { $0.action == .ruleToggle }!
        let update = preset.specs.first { $0.action == .ruleUpdateAmount }!
        let delete = preset.specs.first { $0.action == .ruleDelete }!

        XCTAssertEqual(toggle.policyType, .voteRequired)
        XCTAssertEqual(toggle.approvalConfig?.thresholdPercent, 50)
        XCTAssertEqual(update.approvalConfig?.thresholdPercent, 66, "amount changes require 2/3 in strict")
        XCTAssertEqual(delete.approvalConfig?.thresholdPercent, 66, "deletes require 2/3 in strict")
        XCTAssertEqual(update.approvalConfig?.durationHours, 96)
    }

    func testAllPresetsExposedInOrder() {
        let ids = GroupPolicyPreset.all.map(\.id)
        XCTAssertEqual(ids, ["casual", "balanced", "strict"])
    }
}
