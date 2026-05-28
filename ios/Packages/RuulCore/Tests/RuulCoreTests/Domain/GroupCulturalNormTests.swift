import Foundation
import Testing
@testable import RuulCore

@Suite("GroupCulturalNorm domain")
struct GroupCulturalNormTests {

    @Test("decodes the canonical row from group_cultural_norms_active()")
    func decodesReadShape() throws {
        let nid = UUID(); let gid = UUID(); let uid = UUID()
        let json = """
        {
          "norm_id":                  "\(nid.uuidString)",
          "group_id":                 "\(gid.uuidString)",
          "norm_type":                "value",
          "title":                    "Llegar a tiempo",
          "body":                     "Si avisas con 30 min antes, está bien.",
          "visibility":               "members",
          "status":                   "endorsed",
          "endorsed_count":           3,
          "proposed_by":              "\(uid.uuidString)",
          "proposed_by_display_name": "Ana López",
          "created_at":               null,
          "updated_at":               null
        }
        """.data(using: .utf8)!
        let n = try JSONDecoder().decode(GroupCulturalNorm.self, from: json)
        #expect(n.id == nid)
        #expect(n.groupId == gid)
        #expect(n.type == .value)
        #expect(n.title == "Llegar a tiempo")
        #expect(n.status == .endorsed)
        #expect(n.endorsedCount == 3)
        #expect(n.proposedByDisplayName == "Ana López")
        #expect(n.isEndorsed)
        #expect(!n.isProposed)
    }

    @Test("unknown enums fall back to safe defaults")
    func tolerantEnumFallback() throws {
        let json = """
        {
          "norm_id":        "\(UUID().uuidString)",
          "group_id":       "\(UUID().uuidString)",
          "norm_type":      "future_concept_we_dont_know_yet",
          "title":          "X",
          "visibility":     "tomorrow",
          "status":         "halfway",
          "endorsed_count": 0
        }
        """.data(using: .utf8)!
        let n = try JSONDecoder().decode(GroupCulturalNorm.self, from: json)
        #expect(n.type == .value)
        #expect(n.visibility == .members)
        #expect(n.status == .proposed)
    }

    @Test("body and proposed_by omitted decode as nil")
    func optionalFields() throws {
        let json = """
        {
          "norm_id":        "\(UUID().uuidString)",
          "group_id":       "\(UUID().uuidString)",
          "norm_type":      "principle",
          "title":          "Sin teléfonos en la mesa",
          "visibility":     "members",
          "status":         "proposed",
          "endorsed_count": 0
        }
        """.data(using: .utf8)!
        let n = try JSONDecoder().decode(GroupCulturalNorm.self, from: json)
        #expect(n.body == nil)
        #expect(n.proposedBy == nil)
        #expect(n.proposedByDisplayName == nil)
        #expect(n.type == .principle)
    }
}
