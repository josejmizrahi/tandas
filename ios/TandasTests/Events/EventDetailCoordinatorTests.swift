import Testing
import Foundation
@testable import Tandas

@Suite("EventDetailCoordinator")
@MainActor
struct EventDetailCoordinatorTests {
    private func sampleGroup() -> Group {
        Group(
            id: UUID(), name: "G", inviteCode: "x",
            eventVocabulary: "cena", finesEnabled: true,
            createdBy: UUID(), createdAt: .now
        )
    }

    private func sampleEvent(host: UUID? = nil, group: Group) -> Event {
        Event(
            id: UUID(), groupId: group.id, title: "Cena",
            startsAt: .now.addingTimeInterval(3600),
            hostId: host, createdBy: host, createdAt: .now
        )
    }

    private func makeCoord(viewerIsHost: Bool) -> (EventDetailCoordinator, MockRSVPRepository, MockCheckInRepository, MockEventRepository) {
        let group = sampleGroup()
        let userId = UUID()
        let event = sampleEvent(host: viewerIsHost ? userId : UUID(), group: group)

        let eventRepo = MockEventRepository(seed: [event])
        let rsvpRepo = MockRSVPRepository()
        let checkRepo = MockCheckInRepository()
        let lifecycle = EventLifecycleService(eventRepo: eventRepo)
        let analytics = EventAnalytics(analytics: MockAnalyticsService())

        let coord = EventDetailCoordinator(
            event: event,
            group: group,
            userId: userId,
            eventRepo: eventRepo,
            rsvpRepo: rsvpRepo,
            checkInRepo: checkRepo,
            lifecycle: lifecycle,
            notifications: nil,
            walletService: StubWalletPassService(),
            analytics: analytics
        )
        return (coord, rsvpRepo, checkRepo, eventRepo)
    }

    @Test("viewerRole=host when event.hostId == userId")
    func viewerRoleHost() {
        let (coord, _, _, _) = makeCoord(viewerIsHost: true)
        #expect(coord.viewerRole == .host)
    }

    @Test("viewerRole=guestRole when not host")
    func viewerRoleGuest() {
        let (coord, _, _, _) = makeCoord(viewerIsHost: false)
        #expect(coord.viewerRole == .guestRole)
    }

    @Test("setRSVP optimistic update applies immediately")
    func setRSVPOptimistic() async {
        let (coord, _, _, _) = makeCoord(viewerIsHost: false)
        await coord.setRSVP(.going)
        #expect(coord.myRSVP?.status == .going)
    }

    @Test("setRSVP rolls back on failure")
    func setRSVPRollback() async {
        let (coord, rsvpRepo, _, _) = makeCoord(viewerIsHost: false)
        await rsvpRepo.setNextError(.rsvpFailed("network"))
        await coord.setRSVP(.going)
        #expect(coord.myRSVP == nil)
        #expect(coord.error != nil)
    }

    @Test("hostMarkCheckIn no-op when viewer is guest")
    func hostMarkCheckInGuestNoop() async {
        let (coord, _, checkRepo, _) = makeCoord(viewerIsHost: false)
        await coord.hostMarkCheckIn(memberId: UUID())
        let checkIns = await checkRepo.checkIns
        #expect(checkIns.isEmpty)
    }

    @Test("hostMarkCheckIn fires when viewer is host")
    func hostMarkCheckInWorks() async {
        let (coord, _, checkRepo, _) = makeCoord(viewerIsHost: true)
        await coord.hostMarkCheckIn(memberId: UUID())
        let checkIns = await checkRepo.checkIns
        #expect(checkIns.count == 1)
        #expect(checkIns.first?.method == .hostMarked)
    }

    @Test("closeEvent updates status to closed")
    func closeEventUpdates() async {
        let (coord, _, _, repo) = makeCoord(viewerIsHost: true)
        await coord.closeEvent(autoGenerateEnabled: false)
        let updated = try? await repo.event(coord.event.id)
        #expect(updated?.status == .closed)
    }
}

extension MockRSVPRepository {
    func setNextError(_ err: EventError) {
        nextSetError = err
    }
}
