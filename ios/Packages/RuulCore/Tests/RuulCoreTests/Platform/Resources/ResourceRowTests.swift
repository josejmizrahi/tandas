import Testing
import Foundation
import RuulCore

@Suite("ResourceRow")
struct ResourceRowTests {
    @Test("decodes a row from the resources table json shape")
    func decodesRowJSON() throws {
        let groupId = UUID()
        let resourceId = UUID()
        let createdAt = ISO8601DateFormatter().string(from: .now)
        let json = """
        {
            "id": "\(resourceId.uuidString.lowercased())",
            "group_id": "\(groupId.uuidString.lowercased())",
            "resource_type": "event",
            "status": "scheduled",
            "metadata": {"title": "Cena martes"},
            "created_by": null,
            "created_at": "\(createdAt)",
            "updated_at": "\(createdAt)"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let row = try decoder.decode(ResourceRow.self, from: json)

        #expect(row.id == resourceId)
        #expect(row.groupId == groupId)
        #expect(row.resourceType == .event)
        #expect(row.status == "scheduled")
        #expect(row.metadata["title"]?.stringValue == "Cena martes")
    }

    @Test("survives a row with empty metadata")
    func decodesEmptyMetadata() throws {
        let createdAt = ISO8601DateFormatter().string(from: .now)
        let json = """
        {
            "id": "\(UUID().uuidString.lowercased())",
            "group_id": "\(UUID().uuidString.lowercased())",
            "resource_type": "slot",
            "status": "open",
            "metadata": {},
            "created_at": "\(createdAt)",
            "updated_at": "\(createdAt)"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let row = try decoder.decode(ResourceRow.self, from: json)

        #expect(row.resourceType == .slot)
        #expect(row.metadata == JSONConfig.empty)
    }
}
