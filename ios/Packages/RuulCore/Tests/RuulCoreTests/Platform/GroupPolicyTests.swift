import Foundation
import XCTest
import RuulCore

final class GroupPolicyTests: XCTestCase {

    // MARK: - PolicyDecision

    func testPolicyDecisionDecodesAllowed() throws {
        let json = #"{"decision":"allowed"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(PolicyDecision.self, from: json)
        XCTAssertEqual(decision, .allowed)
    }

    func testPolicyDecisionDecodesVoteRequired() throws {
        let json = #"{"decision":"vote_required","quorum_percent":60,"threshold_percent":66,"duration_hours":48}"#
            .data(using: .utf8)!
        let decision = try JSONDecoder().decode(PolicyDecision.self, from: json)
        XCTAssertEqual(
            decision,
            .voteRequired(quorumPercent: 60, thresholdPercent: 66, durationHours: 48)
        )
    }

    func testPolicyDecisionDecodesAdminOnly() throws {
        let json = #"{"decision":"admin_only"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(PolicyDecision.self, from: json)
        XCTAssertEqual(decision, .adminOnly)
    }

    func testPolicyDecisionDecodesDeniedWithReason() throws {
        let json = #"{"decision":"denied","reason":"not_member"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(PolicyDecision.self, from: json)
        XCTAssertEqual(decision, .denied(reason: "not_member"))
    }

    func testPolicyDecisionRoundTripsVoteRequired() throws {
        let original = PolicyDecision.voteRequired(
            quorumPercent: 50, thresholdPercent: 50, durationHours: 72
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PolicyDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - GroupPolicy + ApprovalConfig

    func testGroupPolicyEncodesWithSnakeCaseKeys() throws {
        let policy = GroupPolicy(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            groupId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            policyType: .voteRequired,
            targetAction: .ruleUpdateAmount,
            approvalConfig: ApprovalConfig(
                quorumPercent: 50,
                thresholdPercent: 66,
                durationHours: 96
            )
        )
        let data = try JSONEncoder().encode(policy)
        let json = String(data: data, encoding: .utf8)!
        // Verify snake_case wire format the SQL side expects.
        XCTAssertTrue(json.contains(#""group_id":"22222222-2222-2222-2222-222222222222""#))
        XCTAssertTrue(json.contains(#""target_action":"rule.update_amount""#))
        XCTAssertTrue(json.contains(#""policy_type":"vote_required""#))
        XCTAssertTrue(json.contains(#""target_scope":"group""#))
        XCTAssertTrue(json.contains(#""quorum_percent":50"#))
        XCTAssertTrue(json.contains(#""threshold_percent":66"#))
        XCTAssertTrue(json.contains(#""duration_hours":96"#))
        XCTAssertTrue(json.contains(#""eligible_voters":"group_members""#))
    }

    func testGroupPolicyDecodesFromServerPayload() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "group_id": "22222222-2222-2222-2222-222222222222",
          "policy_type": "vote_required",
          "target_action": "rule.toggle",
          "target_scope": "group",
          "target_resource_type": null,
          "target_resource_id": null,
          "approval_config": {
            "quorum_percent": 60,
            "threshold_percent": 50,
            "duration_hours": 72,
            "eligible_voters": "group_members"
          },
          "enabled": true,
          "priority": 100
        }
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(GroupPolicy.self, from: json)
        XCTAssertEqual(policy.policyType, .voteRequired)
        XCTAssertEqual(policy.targetAction, .ruleToggle)
        XCTAssertEqual(policy.approvalConfig?.quorumPercent, 60)
        XCTAssertEqual(policy.approvalConfig?.eligibleVoters, .groupMembers)
    }

    // MARK: - PendingChangeEnvelope

    func testEnvelopeEncodesRuleToggle() throws {
        let target = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let env = PendingChangeEnvelope.ruleToggle(
            targetRuleId: target,
            before: .init(isActive: true),
            after:  .init(isActive: false)
        )
        let data = try JSONEncoder().encode(env)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains(#""op":"rule.toggle""#))
        XCTAssertTrue(json.contains(#""target_rule_id":"11111111-1111-1111-1111-111111111111""#))
        XCTAssertTrue(json.contains(#""is_active":false"#))
    }

    func testEnvelopeEncodesRuleUpdateAmount() throws {
        let target = UUID()
        let env = PendingChangeEnvelope.ruleUpdateAmount(
            targetRuleId: target,
            before: .init(amount: 100),
            after:  .init(amount: 200)
        )
        let data = try JSONEncoder().encode(env)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains(#""op":"rule.update_amount""#))
        XCTAssertTrue(json.contains(#""amount":200"#))
    }

    func testEnvelopeEncodesRuleDelete() throws {
        let target = UUID()
        let env = PendingChangeEnvelope.ruleDelete(targetRuleId: target)
        let data = try JSONEncoder().encode(env)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains(#""op":"rule.delete""#))
        XCTAssertTrue(json.contains(#""target_rule_id":"\#(target.uuidString.lowercased())""#)
                      || json.contains(#""target_rule_id":"\#(target.uuidString)""#))
    }

    func testEnvelopeRoundTripsToggle() throws {
        let target = UUID()
        let original = PendingChangeEnvelope.ruleToggle(
            targetRuleId: target,
            before: .init(isActive: true),
            after:  .init(isActive: false)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingChangeEnvelope.self, from: data)
        XCTAssertEqual(decoded.op, .ruleToggle)
        XCTAssertEqual(decoded.targetRuleId, target)
        if case .toggle(let body) = decoded.after.inner {
            XCTAssertEqual(body.isActive, false)
        } else {
            XCTFail("expected .toggle inner, got \(decoded.after.inner)")
        }
    }
}
