import Testing
import Foundation
@testable import Tandas

@Suite("EventCreationCoordinator")
@MainActor
struct EventCreationCoordinatorTests {
    private func sampleGroup(frequency: FrequencyType? = .weekly) -> Group {
        Group(
            id: UUID(),
            name: "Los Cuates",
            inviteCode: "test1234",
            eventVocabulary: "cena",
            frequencyType: frequency,
            frequencyConfig: .weekly(dayOfWeek: 3, hour: 20, minute: 30),
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

    @Test("recurrenceAvailable=true on first event with frequency")
    func recurrenceAvailableTrue() {
        let (coord, _, _) = makeCoord(hasExistingEvents: false)
        #expect(coord.recurrenceAvailable == true)
    }

    @Test("recurrenceAvailable=false when group has existing events")
    func recurrenceAvailableFalseWithExisting() {
        let (coord, _, _) = makeCoord(hasExistingEvents: true)
        #expect(coord.recurrenceAvailable == false)
    }

    @Test("recurrenceAvailable=false when group has no frequency")
    func recurrenceAvailableFalseWithoutFreq() {
        let g = sampleGroup(frequency: nil)
        let (coord, _, _) = makeCoord(group: g, hasExistingEvents: false)
        #expect(coord.recurrenceAvailable == false)
    }

    @Test("publish without title is no-op")
    func publishRequiresTitle() async {
        let (coord, repo, _) = makeCoord()
        coord.draft.title = ""  // empty
        await coord.publish()
        let events = await repo.events
        #expect(events.isEmpty)
        #expect(coord.createdEvent == nil)
    }

    @Test("publish .onlyThis creates 1 event")
    func publishOnlyThis() async {
        let (coord, repo, _) = makeCoord()
        coord.draft.title = "Cena del martes"
        coord.draft.recurrenceOption = .onlyThis
        await coord.publish()
        let events = await repo.events
        #expect(events.count == 1)
        #expect(coord.createdEvent != nil)
    }

    @Test("publish .nextFour creates 1 + 3 = 4 events")
    func publishNextFour() async {
        let (coord, repo, _) = makeCoord()
        coord.draft.title = "Cena recurrente"
        coord.draft.recurrenceOption = .nextFour
        await coord.publish()
        let events = await repo.events
        #expect(events.count == 4)
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
