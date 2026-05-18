import Testing
import Foundation
import RuulCore

@Suite("MockSpaceProjectionRepository")
struct SpaceProjectionRepositoryTests {
    @Test("capacity returns stubbed snapshot or nil")
    func capacityStub() async throws {
        let repo = MockSpaceProjectionRepository()
        let spaceId = UUID()
        let groupId = UUID()

        let beforeStub = try await repo.capacity(for: spaceId)
        #expect(beforeStub == nil)

        let snapshot = SpaceCapacityRow(
            spaceId: spaceId, groupId: groupId,
            capacity: 10, activeBookings: 4, waitlistCount: 2, isFull: false
        )
        await repo.stub(capacity: snapshot, for: spaceId)

        let afterStub = try await repo.capacity(for: spaceId)
        #expect(afterStub == snapshot)
        #expect(afterStub?.remaining == 6)
    }

    @Test("SpaceCapacityRow.remaining handles unlimited capacity")
    func unlimitedCapacityRemaining() {
        let row = SpaceCapacityRow(
            spaceId: UUID(), groupId: UUID(),
            capacity: nil, activeBookings: 5, waitlistCount: 0, isFull: false
        )
        #expect(row.remaining == nil)
    }

    @Test("availability filters by space and respects empty default")
    func availabilityStub() async throws {
        let repo = MockSpaceProjectionRepository()
        let spaceA = UUID()
        let spaceB = UUID()
        let rowA = SpaceAvailabilityRow(
            bookingId: UUID(), spaceId: spaceA, groupId: UUID(), memberId: UUID(),
            startsAt: Date(), endsAt: Date().addingTimeInterval(3600), notes: nil,
            bookedAt: Date()
        )
        await repo.stub(availability: [rowA], for: spaceA)

        let resultA = try await repo.availability(for: spaceA)
        let resultB = try await repo.availability(for: spaceB)
        #expect(resultA.count == 1)
        #expect(resultA.first?.bookingId == rowA.bookingId)
        #expect(resultB.isEmpty)
    }

    @Test("occupancy stub round-trips members in order")
    func occupancyStub() async throws {
        let repo = MockSpaceProjectionRepository()
        let spaceId = UUID()
        let m1 = UUID(), m2 = UUID()
        let r1 = SpaceOccupancyRow(
            spaceId: spaceId, memberId: m1, lastCheckInActionId: UUID(),
            checkedInAt: Date(), bookingId: nil, notes: nil, groupId: UUID()
        )
        let r2 = SpaceOccupancyRow(
            spaceId: spaceId, memberId: m2, lastCheckInActionId: UUID(),
            checkedInAt: Date().addingTimeInterval(-600), bookingId: nil, notes: nil, groupId: UUID()
        )
        await repo.stub(occupancy: [r1, r2], for: spaceId)

        let result = try await repo.occupancy(for: spaceId)
        #expect(result.map(\.memberId) == [m1, m2])
    }

    @Test("history honors limit parameter")
    func historyLimit() async throws {
        let repo = MockSpaceProjectionRepository()
        let spaceId = UUID()
        let rows = (0..<5).map { i in
            SpaceHistoryRow(
                eventId: UUID(), spaceId: spaceId, groupId: UUID(),
                eventType: .spaceBooked, memberId: nil,
                payload: .object([:]), occurredAt: Date().addingTimeInterval(Double(-i * 60))
            )
        }
        await repo.stub(history: rows, for: spaceId)

        let three = try await repo.history(for: spaceId, limit: 3)
        let all = try await repo.history(for: spaceId, limit: 100)
        #expect(three.count == 3)
        #expect(all.count == 5)
    }
}
