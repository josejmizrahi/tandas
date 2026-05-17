import Testing
import Foundation
import RuulCore

@Suite("EventRepository.eventsFromResourceRows")
struct EventRepositoryRowDecodingTests {
    @Test("Mock decodes event rows and skips non-event rows")
    func mockDecodes() async throws {
        let groupId = UUID()
        let eventRow = ResourceRow(
            id: UUID(),
            groupId: groupId,
            resourceType: .event,
            status: "scheduled",
            metadata: .object([
                "title":            .string("Cena"),
                "starts_at":        .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(86_400))),
                "duration_minutes": .int(180)
            ]),
            createdAt: .now,
            updatedAt: .now
        )
        let slotRow = ResourceRow(
            id: UUID(), groupId: groupId, resourceType: .slot,
            status: "open", metadata: .empty,
            createdAt: .now, updatedAt: .now
        )
        let repo = MockEventRepository()

        let events = try await repo.eventsFromResourceRows([eventRow, slotRow])

        #expect(events.count == 1)
        #expect(events.first?.id == eventRow.id)
        #expect(events.first?.title == "Cena")
    }
}
