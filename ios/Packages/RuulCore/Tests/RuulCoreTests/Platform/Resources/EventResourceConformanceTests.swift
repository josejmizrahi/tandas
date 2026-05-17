import Testing
import Foundation
import RuulCore

@Suite("Event: Resource conformance")
struct EventResourceConformanceTests {
    private func sampleEvent() -> Event {
        Event(
            id: UUID(),
            groupId: UUID(),
            title: "Cena",
            startsAt: .now.addingTimeInterval(86_400),
            createdAt: .now
        )
    }

    @Test("Event conforms to Resource via extension")
    func conforms() {
        let event = sampleEvent()
        let resource: any Resource = event

        #expect(resource.id == event.id)
        #expect(resource.groupId == event.groupId)
        #expect(resource.resourceType == .event)
    }

    @Test("resourceStatus bridges via EventStatus.rawValue")
    func statusBridge() {
        let event = sampleEvent()
        let resource: any Resource = event
        #expect(resource.resourceStatus == event.status.rawValue)
    }

    @Test("updatedAt falls back to createdAt when not provided")
    func updatedAtFallback() {
        let event = sampleEvent()
        let resource: any Resource = event
        #expect(resource.updatedAt == resource.createdAt)
    }

    @Test("an array of any Resource can hold Event values")
    func collectionShape() {
        let events = (0..<3).map { _ in sampleEvent() }
        let resources: [any Resource] = events
        #expect(resources.count == 3)
        #expect(resources.allSatisfy { $0.resourceType == .event })
    }
}
