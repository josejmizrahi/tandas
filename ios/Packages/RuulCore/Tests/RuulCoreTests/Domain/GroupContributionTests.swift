import Foundation
import Testing
@testable import RuulCore

@Suite("GroupContribution domain")
struct GroupContributionTests {

    @Test("decodes the canonical row from group_contributions_active()")
    func decodesReadShape() throws {
        let cid = UUID(); let gid = UUID(); let mid = UUID()
        let json = """
        {
          "contribution_id":          "\(cid.uuidString)",
          "group_id":                 "\(gid.uuidString)",
          "membership_id":            "\(mid.uuidString)",
          "member_display_name":      "Ana López",
          "contribution_type":        "hosting",
          "amount":                   "2.5",
          "unit":                     "horas",
          "title":                    "Cena del viernes",
          "description":              "Hosteé en mi casa.",
          "source_resource_id":       null,
          "source_transaction_id":    null,
          "status":                   "claimed",
          "verified_by":              null,
          "verified_by_display_name": null,
          "occurred_at":              null,
          "created_at":               null
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(GroupContribution.self, from: json)
        #expect(c.id == cid)
        #expect(c.type == .hosting)
        #expect(c.amount == Decimal(string: "2.5"))
        #expect(c.unit == "horas")
        #expect(c.title == "Cena del viernes")
        #expect(c.memberDisplayName == "Ana López")
        #expect(c.status == .claimed)
        #expect(c.isQuantified)
        #expect(c.headline == "Cena del viernes")
    }

    @Test("unknown enums fall back to safe defaults")
    func tolerantEnumFallback() throws {
        let json = """
        {
          "contribution_id": "\(UUID().uuidString)",
          "group_id":        "\(UUID().uuidString)",
          "membership_id":   "\(UUID().uuidString)",
          "contribution_type":"future_kind",
          "status":          "wat"
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(GroupContribution.self, from: json)
        #expect(c.type == .other)
        #expect(c.status == .claimed)
    }

    @Test("amount accepts numeric or string framing")
    func tolerantAmount() throws {
        let json = """
        {
          "contribution_id": "\(UUID().uuidString)",
          "group_id":        "\(UUID().uuidString)",
          "membership_id":   "\(UUID().uuidString)",
          "contribution_type":"time",
          "amount":          3.5,
          "unit":            "horas",
          "title":           "Junta",
          "status":          "claimed"
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(GroupContribution.self, from: json)
        #expect(c.amount == Decimal(string: "3.5"))
    }

    @Test("headline falls back to description then type")
    func headlineFallbacks() {
        let typeFallback = GroupContribution(
            id: UUID(),
            groupId: UUID(),
            membershipId: UUID(),
            type: .care
        )
        #expect(typeFallback.headline == String(localized: ContributionType.care.label))

        let descFallback = GroupContribution(
            id: UUID(),
            groupId: UUID(),
            membershipId: UUID(),
            type: .docs,
            description: "Escribí el README"
        )
        #expect(descFallback.headline == "Escribí el README")
    }
}
