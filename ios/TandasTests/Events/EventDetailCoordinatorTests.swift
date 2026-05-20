import Testing
import Foundation
import RuulUI
import RuulCore
import RuulFeatures
@testable import Tandas

@Suite("EventDetailCoordinator")
@MainActor
struct EventDetailCoordinatorTests {
    private func sampleGroup() -> Group {
        Group(
            id: UUID(), name: "G", inviteCode: "x",
            activeModules: ["basic_fines", "rsvp", "check_in"],
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

    // V1-14 (FASE 0 correctness): isMutating guard blocks a re-tap fired
    // while the first server call is in-flight. Deterministic version —
    // a holding RSVP repo pauses the first call until we explicitly
    // resume it, so we can verify that a second call attempted while
    // isMutating==true short-circuits inside the guard and never
    // reaches the repo.
    @Test("setRSVP double-tap: isMutating guard prevents second call while first is in-flight")
    func setRSVPDoubleTapGuard() async {
        let holdingRepo = HoldingRSVPRepository()
        let group = sampleGroup()
        let event = sampleEvent(host: UUID(), group: group)
        let eventRepo = MockEventRepository(seed: [event])
        let coord = EventDetailCoordinator(
            event: event,
            group: group,
            userId: UUID(),
            eventRepo: eventRepo,
            rsvpRepo: holdingRepo,
            checkInRepo: MockCheckInRepository(),
            lifecycle: EventLifecycleService(eventRepo: eventRepo),
            notifications: nil,
            walletService: StubWalletPassService(),
            analytics: EventAnalytics(analytics: MockAnalyticsService())
        )

        // T1: kick off the first setRSVP. It enters the coordinator,
        // sets isMutating=true, awaits rsvpRepo.setRSVP, and is held
        // there by the holding repo's continuation.
        let t1 = Task { await coord.setRSVP(.going) }

        // Wait until T1 has reached the held setRSVP (isMutating=true).
        // Bounded so the test fails fast on a hang rather than spinning.
        var spins = 0
        while !coord.isMutating && spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        #expect(coord.isMutating, "T1 must have entered setRSVP and set isMutating=true")

        // T2: while T1 is still held, fire a second setRSVP from the
        // test scope. The guard `guard !isMutating else { return }`
        // must short-circuit immediately. holdingRepo.callCount stays 1.
        await coord.setRSVP(.declined)
        let callsDuringHold = await holdingRepo.callCount
        #expect(callsDuringHold == 1, "second setRSVP must NOT reach the repo while T1 is in-flight")

        // Release T1 and let it finish.
        await holdingRepo.resumeAll()
        await t1.value

        let finalCalls = await holdingRepo.callCount
        #expect(finalCalls == 1, "still exactly one repo call after both tasks settled")
        #expect(coord.isMutating == false, "isMutating must reset after T1 completes")
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

/// V1-14 helper. RSVPRepository whose `setRSVP` blocks on a continuation
/// per call until the test explicitly resumes it. Lets the double-tap
/// test pin the in-flight state deterministically.
actor HoldingRSVPRepository: RSVPRepository {
    private(set) var callCount: Int = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func rsvps(for eventId: UUID) async throws -> [RSVP] { [] }
    func myRSVP(for eventId: UUID, userId: UUID) async throws -> RSVP? { nil }
    func promoteFromWaitlist(eventId: UUID) async throws -> RSVP {
        throw EventError.notFound
    }

    func setRSVP(eventId: UUID, status: RSVPStatus, plusOnes: Int, reason: String?) async throws -> RSVP {
        callCount += 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuations.append(cont)
        }
        return RSVP(
            id: UUID(),
            eventId: eventId,
            userId: UUID(),
            status: status,
            respondedAt: .now,
            cancelledReason: reason,
            plusOnes: plusOnes
        )
    }

    func resumeAll() {
        for c in continuations { c.resume() }
        continuations.removeAll()
    }
}
