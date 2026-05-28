import Foundation
import Testing
@testable import RuulCore

@Suite("GroupDecisionRules domain")
struct GroupDecisionRulesTests {

    @Test("displayOrder is admin_only → majority → supermajority → unanimity → consensus")
    func displayOrder() {
        #expect(DecisionStyle.displayOrder == [
            .adminOnly, .majority, .supermajority, .unanimity, .consensus
        ])
    }

    @Test("decodes the canonical jsonb returned by group_decision_rules()")
    func decodesReadShape() throws {
        let gid = UUID()
        let json = """
        {
          "group_id":                  "\(gid.uuidString)",
          "default_style":             "supermajority",
          "default_method":            "supermajority",
          "default_legitimacy_source": "supermajority",
          "quorum_min":                3,
          "notes":                     "Decidimos en la cena del viernes.",
          "is_default":                false
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupDecisionRules.self, from: json)
        #expect(r.groupId == gid)
        #expect(r.defaultStyle == .supermajority)
        #expect(r.defaultMethod == .supermajority)
        #expect(r.defaultLegitimacySource == .supermajority)
        #expect(r.quorumMin == 3)
        #expect(r.notes == "Decidimos en la cena del viernes.")
        #expect(r.isDefault == false)
    }

    @Test("decodes nulls into nil quorum + nil notes and falls back to derived defaults")
    func decodesNulls() throws {
        let gid = UUID()
        let json = """
        {
          "group_id":      "\(gid.uuidString)",
          "default_style": "majority",
          "quorum_min":    null,
          "notes":         null,
          "is_default":    true
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupDecisionRules.self, from: json)
        #expect(r.quorumMin == nil)
        #expect(r.notes == nil)
        #expect(r.isDefault)
        // No method/legitimacy in the payload — derive from style.
        #expect(r.defaultMethod == .majority)
        #expect(r.defaultLegitimacySource == .majority)
    }

    @Test("legacy payload (no method/legitimacy keys) derives canonical pair from style")
    func legacyPayloadDerives() throws {
        let gid = UUID()
        let json = """
        {
          "group_id":      "\(gid.uuidString)",
          "default_style": "unanimity",
          "is_default":    false
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupDecisionRules.self, from: json)
        #expect(r.defaultMethod == .consensus)
        #expect(r.defaultLegitimacySource == .unanimity)
    }

    @Test("unknown default_style falls back to .majority")
    func unknownStyleFallback() throws {
        let json = """
        {
          "group_id":      "\(UUID().uuidString)",
          "default_style": "future_style",
          "quorum_min":    null,
          "notes":         null,
          "is_default":    false
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(GroupDecisionRules.self, from: json)
        #expect(r.defaultStyle == .majority)
    }

    @Test("DecisionMethod.forStyle covers every legacy style")
    func forStyleMapping() {
        #expect(DecisionMethod.forStyle(.adminOnly) == .admin)
        #expect(DecisionMethod.forStyle(.majority) == .majority)
        #expect(DecisionMethod.forStyle(.supermajority) == .supermajority)
        #expect(DecisionMethod.forStyle(.unanimity) == .consensus)
        #expect(DecisionMethod.forStyle(.consensus) == .consent)
    }

    @Test("trimmedNotes drops whitespace + returns nil when empty")
    func trimmedNotes() {
        let blank = GroupDecisionRules(groupId: UUID(), defaultStyle: .majority,
                                       notes: "   \n  ", isDefault: false)
        #expect(blank.trimmedNotes == nil)

        let filled = GroupDecisionRules(groupId: UUID(), defaultStyle: .majority,
                                        notes: "  hola  ", isDefault: false)
        #expect(filled.trimmedNotes == "hola")
    }
}
