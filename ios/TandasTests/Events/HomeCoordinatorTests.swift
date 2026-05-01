import Testing
import Foundation
@testable import Tandas

@Suite("HomeCoordinator")
@MainActor
struct HomeCoordinatorTests {
    private func sampleGroup() -> Group {
        Group(id: UUID(), name: "G", inviteCode: "x", createdBy: UUID(), createdAt: .now)
    }

    private func sampleEvent(in group: Group, daysAhead: Int) -> Event {
        Event(
            id: UUID(), groupId: group.id, title: "E\(daysAhead)",
            startsAt: .now.addingTimeInterval(TimeInterval(daysAhead) * 86_400),
            createdAt: .now
        )
    }

    @Test("refresh populates upcomingEvents and nextEvent")
    func refreshPopulates() async {
        let group = sampleGroup()
        let userId = UUID()
        let events = [sampleEvent(in: group, daysAhead: 7), sampleEvent(in: group, daysAhead: 14)]
        let repo = MockEventRepository(seed: events)
        let coord = HomeCoordinator(group: group, userId: userId, eventRepo: repo, rsvpRepo: MockRSVPRepository())

        await coord.refresh(force: true)
        #expect(coord.upcomingEvents.count == 2)
        #expect(coord.nextEvent?.startsAt == events.first!.startsAt)
    }

    @Test("refresh respects 5min cache TTL")
    func refreshCached() async {
        let group = sampleGroup()
        let repo = MockEventRepository(seed: [sampleEvent(in: group, daysAhead: 1)])
        let coord = HomeCoordinator(group: group, userId: UUID(), eventRepo: repo, rsvpRepo: MockRSVPRepository())

        await coord.refresh(force: false)
        let firstFetched = coord.lastRefreshedAt
        await coord.refresh(force: false)  // should be skipped
        #expect(coord.lastRefreshedAt == firstFetched)
    }

    @Test("empty group has nil nextEvent")
    func emptyGroup() async {
        let group = sampleGroup()
        let coord = HomeCoordinator(group: group, userId: UUID(), eventRepo: MockEventRepository(), rsvpRepo: MockRSVPRepository())
        await coord.refresh(force: true)
        #expect(coord.nextEvent == nil)
        #expect(coord.upcomingEvents.isEmpty)
    }
}
