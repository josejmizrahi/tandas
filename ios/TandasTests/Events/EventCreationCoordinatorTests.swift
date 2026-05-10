import Testing
import Foundation
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("EventCreationCoordinator")
@MainActor
struct EventCreationCoordinatorTests {
    private func sampleGroup() -> Group {
        Group(
            id: UUID(),
            name: "Los Cuates",
            inviteCode: "test1234",
            createdBy: UUID(),
            createdAt: .now
        )
    }

    private func makeCoord(
        group: Group? = nil,
        hasExistingEvents: Bool = false,
        eventRepo: MockEventRepository = .init()
    ) -> (EventCreationCoordinator, MockEventRepository, MockAnalyticsService) {
        let g = group ?? sampleGroup()
        let analytics = MockAnalyticsService()
        let lifecycle = EventLifecycleService(eventRepo: eventRepo)
        let coord = EventCreationCoordinator(
            group: g,
            hasExistingEvents: hasExistingEvents,
            suggestedDate: .now.addingTimeInterval(86_400),
            eventRepo: eventRepo,
            lifecycle: lifecycle,
            analytics: EventAnalytics(analytics: analytics)
        )
        return (coord, eventRepo, analytics)
    }

    @Test("recurrenceAvailable always false post BigBang")
    func recurrenceAvailableFalse() {
        // Group-level recurrence is gone post BigBang. ResourceSeries (Phase 2)
        // will reintroduce it with its own coordinator.
        let (coord, _, _) = makeCoord(hasExistingEvents: false)
        #expect(coord.recurrenceAvailable == false)
    }

    @Test("publish without title is no-op")
    func publishRequiresTitle() async {
        let (coord, repo, _) = makeCoord()
        coord.draft.title = ""
        await coord.publish()
        let events = await repo.events
        #expect(events.isEmpty)
        #expect(coord.createdEvent == nil)
    }

    @Test("publish creates a single event (no recurrence cascade)")
    func publishSingleEvent() async {
        let (coord, repo, _) = makeCoord()
        coord.draft.title = "Cena del martes"
        coord.draft.recurrenceOption = .onlyThis
        await coord.publish()
        let events = await repo.events
        #expect(events.count == 1)
        #expect(coord.createdEvent != nil)
    }

    @Test("publish failure surfaces error")
    func publishFailure() async {
        let repo = MockEventRepository()
        await repo.setNextCreateError(.createFailed("network"))
        let (coord, _, _) = makeCoord(eventRepo: repo)
        coord.draft.title = "Cena"
        await coord.publish()
        #expect(coord.error != nil)
        #expect(coord.createdEvent == nil)
    }
}

extension MockEventRepository {
    func setNextCreateError(_ err: EventError) {
        nextCreateError = err
    }
}
