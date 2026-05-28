import Foundation
import Testing
@testable import RuulCore

@Suite("RuleShape + EngineRule wire decoding")
struct RuleShapeTests {

    @Test("trigger atom decodes with scope + payload hints")
    func decodesTriggerAtom() throws {
        let json = """
        {
          "shape_key":      "trigger.money.expense_recorded",
          "category":       "trigger",
          "display_name":   "Cuando alguien registra un gasto",
          "description":    "Se dispara cuando un miembro guarda un nuevo gasto.",
          "schema": {
            "event_type": "money.expense_recorded",
            "payload_keys": ["amount", "currency"],
            "compatible_conditions": ["condition.amount_above"],
            "compatible_consequences": ["consequence.issue_sanction"],
            "scope": "group"
          },
          "resource_types": [],
          "metadata": { "icon": "dollarsign.bank.building" }
        }
        """.data(using: .utf8)!
        let shape = try JSONDecoder().decode(RuleShape.self, from: json)
        #expect(shape.category == .trigger)
        #expect(shape.triggerEventType == "money.expense_recorded")
        #expect(shape.schema.scope == .group)
        #expect(shape.compatibleConditionKeys == ["condition.amount_above"])
        #expect(shape.iconSystemName == "dollarsign.bank.building")
    }

    @Test("consequence atom decodes with execution + authority")
    func decodesConsequenceAtom() throws {
        let json = """
        {
          "shape_key":     "consequence.issue_sanction",
          "category":      "consequence",
          "display_name":  "Emitir sanción",
          "description":   null,
          "schema": {
            "action": "issue_sanction",
            "execution": "sync",
            "authority_required": "sanctions.create",
            "fields": [
              { "key": "severity", "type": "integer", "required": true, "min": 1, "max": 5, "label": "Severidad" },
              { "key": "reason",   "type": "string",  "required": true, "label": "Razón" }
            ]
          },
          "resource_types": [],
          "metadata": {}
        }
        """.data(using: .utf8)!
        let shape = try JSONDecoder().decode(RuleShape.self, from: json)
        #expect(shape.category == .consequence)
        #expect(shape.execution == .sync)
        #expect(shape.authorityRequired == "sanctions.create")
        #expect(shape.fields.count == 2)
        #expect(shape.fields.first?.isRequired == true)
    }

    @Test("send_notification consequence flagged async")
    func decodesAsyncConsequence() throws {
        let json = """
        {
          "shape_key":     "consequence.send_notification",
          "category":      "consequence",
          "display_name":  "Enviar notificación",
          "description":   null,
          "schema": {
            "action": "send_notification",
            "execution": "async",
            "authority_required": null,
            "fields": [
              { "key": "message", "type": "string", "required": true }
            ]
          },
          "resource_types": [],
          "metadata": {}
        }
        """.data(using: .utf8)!
        let shape = try JSONDecoder().decode(RuleShape.self, from: json)
        #expect(shape.execution == .async)
        #expect(shape.authorityRequired == nil)
    }

    @Test("validate_rule_shape error response decodes")
    func decodesValidationErrorResponse() throws {
        let json = """
        {
          "valid": false,
          "errors": [
            { "path": "shape_key", "code": "required", "message": "shape_key requerido" },
            { "path": "consequences[0].fields.severity", "code": "type", "message": "severity debe ser número" }
          ],
          "shape_key": null,
          "trigger_event_type": null
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(RuleShapeValidationResult.self, from: json)
        #expect(result.valid == false)
        #expect(result.errors.count == 2)
        #expect(result.errors[1].code == "type")
    }

    @Test("validate_rule_shape success response decodes")
    func decodesValidationGoldenResponse() throws {
        let json = """
        {
          "valid": true,
          "errors": [],
          "shape_key": "trigger.money.expense_recorded",
          "trigger_event_type": "money.expense_recorded"
        }
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(RuleShapeValidationResult.self, from: json)
        #expect(result.valid)
        #expect(result.shapeKey == "trigger.money.expense_recorded")
        #expect(result.triggerEventType == "money.expense_recorded")
    }

    @Test("EngineRule decodes from group_rules_engine row")
    func decodesEngineRule() throws {
        let rid = UUID(); let vid = UUID(); let gid = UUID()
        let json = """
        {
          "rule_id":            "\(rid.uuidString)",
          "current_version_id": "\(vid.uuidString)",
          "group_id":           "\(gid.uuidString)",
          "title":              "Excede tope = sanción",
          "rule_type":          "requirement",
          "severity":           2,
          "status":             "active",
          "created_by":         null,
          "effective_from":     null,
          "created_at":         null,
          "updated_at":         null,
          "shape_key":          "trigger.money.expense_recorded",
          "trigger_event_type": "money.expense_recorded",
          "condition_tree": {
            "kind": "condition.amount_above",
            "fields": { "amount": 1000, "currency": "MXN" }
          },
          "consequences": [
            {
              "kind": "consequence.issue_sanction",
              "fields": { "severity": 2, "reason": "Excede tope" }
            }
          ]
        }
        """.data(using: .utf8)!
        let rule = try JSONDecoder().decode(EngineRule.self, from: json)
        #expect(rule.id == rid)
        #expect(rule.shapeKey == "trigger.money.expense_recorded")
        #expect(rule.condition?.kind == "condition.amount_above")
        #expect(rule.consequences.count == 1)
        #expect(rule.consequences.first?.kind == "consequence.issue_sanction")
        // Field values round-trip via RPCJSONValue.
        if case .number(let n)? = rule.condition?.fields["amount"] {
            #expect(n == 1000)
        } else {
            Issue.record("amount did not decode as number")
        }
    }

    @Test("CreateEngineRuleResult decodes snake_case")
    func decodesCreateResult() throws {
        let rid = UUID(); let vid = UUID()
        let json = """
        { "rule_id": "\(rid.uuidString)", "version_id": "\(vid.uuidString)" }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(CreateEngineRuleResult.self, from: json)
        #expect(r.ruleId == rid)
        #expect(r.versionId == vid)
    }

    @Test("RuleShapePayload round-trip preserves nested fields")
    func payloadRoundTrip() throws {
        let payload = RuleShapePayload(
            shapeKey: "trigger.money.expense_recorded",
            conditionTree: EngineRuleCondition(
                kind: "condition.amount_above",
                fields: ["amount": .number(750), "currency": .string("MXN")]
            ),
            consequences: [
                EngineRuleConsequence(
                    kind: "consequence.send_notification",
                    fields: ["message": .string("Gasto alto"),
                             "audience": .string("admins")]
                )
            ]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RuleShapePayload.self, from: data)
        #expect(decoded == payload)
    }
}
