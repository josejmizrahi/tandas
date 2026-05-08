import XCTest
import RuulUI
import RuulCore
@testable import Tandas

final class EventResourceTests: XCTestCase {

    // MARK: - Fixture

    private func makeEvent(
        id: UUID = UUID(),
        groupId: UUID = UUID()
    ) -> Event {
        Event(
            id: id,
            groupId: groupId,
            title: "Test event",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Tests

    func testInitPreservesEventIdentity() {
        let id = UUID()
        let groupId = UUID()
        let event = makeEvent(id: id, groupId: groupId)
        let resource = EventResource(event)

        XCTAssertEqual(resource.id, id)
        XCTAssertEqual(resource.groupId, groupId)
    }

    func testResourceTypeAlwaysEvent() {
        let resource = EventResource(makeEvent())
        XCTAssertEqual(resource.resourceType, .event)
    }

    func testEventPropertyReturnsOriginal() {
        let event = makeEvent()
        let resource = EventResource(event)
        XCTAssertEqual(resource.event, event)
    }

    func testIdentifiableInCollections() {
        let resources = (0..<3).map { _ in EventResource(makeEvent()) }
        let ids = Set(resources.map(\.id))
        XCTAssertEqual(ids.count, 3, "three distinct resources should have three distinct ids")
    }
}
