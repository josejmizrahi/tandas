import Testing
import Foundation
import RuulCore

@Suite("ResourceRow.decodeAsEvent")
struct ResourceRowEventDecoderTests {
    private func sampleRow(
        type: ResourceType = .event,
        title: String = "Cena martes",
        startsAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> ResourceRow {
        let iso = ISO8601DateFormatter().string(from: startsAt)
        let metadata: JSONConfig = .object([
            "title":            .string(title),
            "starts_at":        .string(iso),
            "duration_minutes": .int(180),
            "apply_rules":      .bool(true)
        ])
        return ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: type,
            status: "scheduled",
            metadata: metadata,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @Test("decodes event metadata into Event")
    func happyPath() throws {
        let row = sampleRow(title: "Cena Sábado")

        let event = try row.decodeAsEvent()

        #expect(event.id == row.id)
        #expect(event.groupId == row.groupId)
        #expect(event.title == "Cena Sábado")
        #expect(event.durationMinutes == 180)
        #expect(event.applyRules == true)
    }

    @Test("throws typeMismatch when row is not an event")
    func typeMismatch() throws {
        let row = sampleRow(type: .slot)

        #expect(throws: ResourceRowError.typeMismatch(expected: .event, got: .slot)) {
            _ = try row.decodeAsEvent()
        }
    }

    @Test("throws missingMetadataKey when starts_at is absent")
    func missingStartsAt() throws {
        let row = ResourceRow(
            id: UUID(), groupId: UUID(), resourceType: .event,
            status: "scheduled",
            metadata: .object(["title": .string("x")]),
            createdAt: .now, updatedAt: .now
        )

        #expect(throws: ResourceRowError.missingMetadataKey("starts_at")) {
            _ = try row.decodeAsEvent()
        }
    }
}
