import Testing
import Foundation
import RuulCore

@Suite("MockSpaceLifecycleRepository")
struct SpaceLifecycleRepositoryTests {
    @Test("bookSpace records a booking + returns a stable id")
    func bookSpaceRecords() async throws {
        let repo = MockSpaceLifecycleRepository()
        let spaceId = UUID()
        let start = Date()
        let end = start.addingTimeInterval(3600)

        let bookingId = try await repo.bookSpace(
            space: spaceId, startsAt: start, endsAt: end, notes: "Cumpleaños"
        )
        let stored = await repo.bookings
        #expect(stored.count == 1)
        #expect(stored.first?.bookingId == bookingId)
        #expect(stored.first?.spaceId == spaceId)
        #expect(stored.first?.startsAt == start)
        #expect(stored.first?.endsAt == end)
    }

    @Test("bookSpace throws capacityReached when simulated cap is exhausted")
    func bookSpaceRespectsCapacity() async throws {
        let repo = MockSpaceLifecycleRepository()
        await repo.setSimulatedCapacity(1)
        let spaceId = UUID()

        _ = try await repo.bookSpace(space: spaceId, startsAt: nil, endsAt: nil, notes: nil)

        await #expect(throws: SpaceLifecycleError.self) {
            _ = try await repo.bookSpace(space: spaceId, startsAt: nil, endsAt: nil, notes: nil)
        }
    }

    @Test("cancelBooking records the booking id for projection cancellation")
    func cancelBookingRecords() async throws {
        let repo = MockSpaceLifecycleRepository()
        let bookingId = UUID()
        try await repo.cancelBooking(booking: bookingId, reason: "test")
        let cancellations = await repo.cancellations
        #expect(cancellations == [bookingId])
    }

    @Test("joinWaitlist records space id and returns atom id")
    func joinWaitlistRecords() async throws {
        let repo = MockSpaceLifecycleRepository()
        let spaceId = UUID()
        let atomId = try await repo.joinWaitlist(space: spaceId, priority: 50, notes: nil)
        let joins = await repo.waitlistJoins
        #expect(joins == [spaceId])
        #expect(atomId != UUID()) // any UUID, just verifying non-throw
    }

    @Test("promoteFromWaitlist records and returns atom id by default")
    func promoteRecords() async throws {
        let repo = MockSpaceLifecycleRepository()
        let spaceId = UUID()
        let atomId = try await repo.promoteFromWaitlist(space: spaceId)
        #expect(atomId != nil)
        let promotions = await repo.waitlistPromotions
        #expect(promotions == [spaceId])
    }

    @Test("checkInToSpace records action + optional booking id")
    func checkInRecords() async throws {
        let repo = MockSpaceLifecycleRepository()
        let spaceId = UUID()
        let bookingId = UUID()
        _ = try await repo.checkInToSpace(space: spaceId, booking: bookingId, notes: nil)
        let checkIns = await repo.checkIns
        #expect(checkIns.count == 1)
        #expect(checkIns.first?.0 == spaceId)
        #expect(checkIns.first?.1 == bookingId)
    }

    @Test("grantSpaceAccess + revokeSpaceAccess record the pair")
    func accessGrants() async throws {
        let repo = MockSpaceLifecycleRepository()
        let spaceId = UUID()
        let memberId = UUID()
        let until = Date().addingTimeInterval(86400)

        try await repo.grantSpaceAccess(
            space: spaceId, to: memberId, until: until, reason: "invitado"
        )
        try await repo.revokeSpaceAccess(
            space: spaceId, member: memberId, reason: "fin del evento"
        )
        let grants = await repo.accessGrants
        let revokes = await repo.accessRevokes
        #expect(grants.count == 1)
        #expect(grants.first?.0 == spaceId)
        #expect(grants.first?.1 == memberId)
        #expect(grants.first?.2 == until)
        #expect(revokes.count == 1)
        #expect(revokes.first?.0 == spaceId)
        #expect(revokes.first?.1 == memberId)
    }

    @Test("updateSpaceMetadata captures the patch payload")
    func metadataPatch() async throws {
        let repo = MockSpaceLifecycleRepository()
        let spaceId = UUID()
        let patch: JSONConfig = .object([
            "name": .string("Nuevo nombre"),
            "capacity": .int(75)
        ])
        try await repo.updateSpaceMetadata(space: spaceId, patch: patch)
        let patches = await repo.metadataPatches
        #expect(patches.count == 1)
        #expect(patches.first?.0 == spaceId)
        #expect(patches.first?.1 == patch)
    }

    @Test("nextError is propagated on the next call only")
    func errorPropagation() async throws {
        let repo = MockSpaceLifecycleRepository()
        await repo.setNextError(.permissionDenied("only admins"))
        await #expect(throws: SpaceLifecycleError.self) {
            try await repo.cancelBooking(booking: UUID(), reason: nil)
        }
        // Subsequent call succeeds (error was consumed).
        try await repo.cancelBooking(booking: UUID(), reason: nil)
    }
}

// MARK: - Actor accessors for tests (matching pattern in MockAssetLifecycleRepository)

extension MockSpaceLifecycleRepository {
    func setSimulatedCapacity(_ cap: Int) {
        self.simulatedCapacity = cap
    }
    func setNextError(_ error: SpaceLifecycleError) {
        self.nextError = error
    }
}
