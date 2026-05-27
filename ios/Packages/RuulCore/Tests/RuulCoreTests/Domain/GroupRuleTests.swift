import Foundation
import Testing
@testable import RuulCore

@Suite("GroupRule domain")
struct GroupRuleTests {

    @Test("decodes a text rule row from group_rules_active")
    func decodesTextRow() throws {
        let rid = UUID(); let vid = UUID(); let gid = UUID()
        let json = """
        {
          "rule_id":            "\(rid.uuidString)",
          "current_version_id": "\(vid.uuidString)",
          "group_id":           "\(gid.uuidString)",
          "title":              "Sin celulares",
          "body":               "Apaga el teléfono",
          "rule_type":          "prohibition",
          "severity":           3,
          "execution_mode":     "text",
          "status":             "active",
          "created_by":         null,
          "effective_from":     null,
          "created_at":         null,
          "updated_at":         null
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupRule.self, from: json)
        #expect(r.id == rid)
        #expect(r.currentVersionId == vid)
        #expect(r.title == "Sin celulares")
        #expect(r.body == "Apaga el teléfono")
        #expect(r.ruleType == .prohibition)
        #expect(r.severity == 3)
        #expect(r.executionMode == .text)
        #expect(r.isHighSeverity == true)
    }

    @Test("unknown enum values fall back to safe defaults")
    func defensiveFallbacks() throws {
        let json = """
        {
          "rule_id":            "\(UUID().uuidString)",
          "current_version_id": null,
          "group_id":           "\(UUID().uuidString)",
          "title":              "Mystery",
          "body":               "",
          "rule_type":          "future_kind",
          "severity":           1,
          "execution_mode":     "future_mode",
          "status":             "active"
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupRule.self, from: json)
        #expect(r.ruleType == .norm)
        #expect(r.executionMode == .text)
    }

    @Test("CreateTextRuleResult decodes snake_case")
    func createResultDecode() throws {
        let rid = UUID(); let vid = UUID()
        let json = """
        { "rule_id": "\(rid.uuidString)", "version_id": "\(vid.uuidString)" }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(CreateTextRuleResult.self, from: json)
        #expect(r.ruleId == rid)
        #expect(r.versionId == vid)
    }
}
