import Foundation
import Testing
@testable import RuulCore

@Suite("list_my_groups decoding")
struct ListMyGroupsDecodingTests {

    private func decode(_ json: String) throws -> ListMyGroupsRow {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(ListMyGroupsRow.self, from: data)
    }

    @Test("snake_case row decodes and maps to GroupListItem")
    func decodesAndMaps() throws {
        let mid = UUID()
        let gid = UUID()
        let json = """
        {
          "membership_id": "\(mid.uuidString)",
          "group_id":      "\(gid.uuidString)",
          "name":          "Bros",
          "slug":          "bros",
          "category":      "friends",
          "purpose_summary": "Chill",
          "joined_at":     null
        }
        """
        let row = try decode(json)
        #expect(row.membershipId == mid)
        #expect(row.groupId == gid)
        #expect(row.name == "Bros")
        #expect(row.purposeSummary == "Chill")

        let item = row.toDomain()
        #expect(item.id == gid)              // GroupListItem.id is the group_id, NOT membership
        #expect(item.membershipId == mid)
        #expect(item.name == "Bros")
        #expect(item.slug == "bros")
        #expect(item.purposeSummary == "Chill")
    }

    @Test("optional slug/category/purpose_summary decode as nil when absent")
    func handlesMissingOptionals() throws {
        let json = """
        {
          "membership_id": "\(UUID().uuidString)",
          "group_id":      "\(UUID().uuidString)",
          "name":          "Solo",
          "slug":          null,
          "category":      null,
          "purpose_summary": null,
          "joined_at":     null
        }
        """
        let row = try decode(json)
        #expect(row.slug == nil)
        #expect(row.category == nil)
        #expect(row.purposeSummary == nil)
    }
}
