import Foundation
import Testing
@testable import RuulCore

@Suite("GroupRuleEvaluation wire decoding (V2-G3.5)")
struct GroupRuleEvaluationTests {

    @Test("decodes a passed row with one emitted action and pre-G3.4 fields")
    func decodesPassedRow() throws {
        let evalId = UUID(); let ruleId = UUID(); let versionId = UUID()
        let json = """
        {
          "evaluation_id":        "\(evalId.uuidString)",
          "rule_id":              "\(ruleId.uuidString)",
          "rule_title":           "Excede tope",
          "rule_version_id":      "\(versionId.uuidString)",
          "shape_key":            "trigger.money.expense_recorded",
          "trigger_event_type":   "money.expense_recorded",
          "source_event_id":      null,
          "matched":              true,
          "cycle_detected":       false,
          "depth":                0,
          "matched_predicate": {
            "passed": true,
            "reason": "above_threshold",
            "kind":   "condition.amount_above",
            "evaluated_value": { "event_amount": 750, "threshold": 500 }
          },
          "actions_emitted": [
            { "kind": "consequence.send_notification",
              "execution": "async",
              "status": "emitted",
              "audience": "admins",
              "recipients": 1 }
          ],
          "parent_evaluation_id": null,
          "created_at": "2026-05-28T20:15:45Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(GroupRuleEvaluation.self, from: json)
        #expect(row.id == evalId)
        #expect(row.ruleTitle == "Excede tope")
        #expect(row.matched)
        #expect(row.depth == 0)
        #expect(row.matchedPredicate?.passed == true)
        #expect(row.matchedPredicate?.reason == "above_threshold")
        #expect(row.actionsEmitted.count == 1)
        let action = row.actionsEmitted[0]
        #expect(action.kind == "consequence.send_notification")
        #expect(action.isEmitted)
        #expect(action.audience == "admins")
        #expect(action.recipients == 1)
    }

    @Test("decodes a failed sync action with error captured")
    func decodesFailedSyncAction() throws {
        let json = """
        {
          "evaluation_id":     "\(UUID().uuidString)",
          "rule_id":           "\(UUID().uuidString)",
          "rule_title":        "Sanción inmediata",
          "rule_version_id":   "\(UUID().uuidString)",
          "matched":           true,
          "actions_emitted":   [
            { "kind": "consequence.issue_sanction",
              "execution": "sync",
              "status": "failed",
              "error": "caller lacks permission sanctions.create" }
          ],
          "created_at": "2026-05-28T20:07:39Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(GroupRuleEvaluation.self, from: json)
        #expect(row.actionsEmitted.first?.isFailed == true)
        #expect(row.actionsEmitted.first?.error == "caller lacks permission sanctions.create")
        #expect(row.failedActions.count == 1)
        #expect(row.emittedActions.isEmpty)
    }

    @Test("cycle_detected row reports correct summary + no emitted actions")
    func decodesCycleRow() throws {
        let json = """
        {
          "evaluation_id":     "\(UUID().uuidString)",
          "rule_id":           "\(UUID().uuidString)",
          "rule_title":        "Loop",
          "rule_version_id":   "\(UUID().uuidString)",
          "matched":           true,
          "cycle_detected":    true,
          "depth":             1,
          "actions_emitted":   [],
          "created_at": "2026-05-28T20:07:39Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(GroupRuleEvaluation.self, from: json)
        #expect(row.cycleDetected)
        #expect(row.summary == "Ciclo detectado — sin disparo")
    }

    @Test("matched=false row summary is 'No coincidió'")
    func decodesNoMatchRow() throws {
        let json = """
        {
          "evaluation_id":     "\(UUID().uuidString)",
          "rule_id":           "\(UUID().uuidString)",
          "rule_title":        "Below threshold",
          "rule_version_id":   "\(UUID().uuidString)",
          "matched":           false,
          "matched_predicate": { "passed": false, "reason": "below_threshold", "kind": "condition.amount_above" },
          "actions_emitted":   [],
          "created_at": "2026-05-28T20:07:39Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(GroupRuleEvaluation.self, from: json)
        #expect(row.matched == false)
        #expect(row.summary == "No coincidió")
    }
}
