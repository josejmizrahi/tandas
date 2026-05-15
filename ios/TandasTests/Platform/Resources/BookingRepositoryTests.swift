import Testing
import Foundation
import RuulCore

@Suite("MockBookingRepository")
struct BookingRepositoryTests {
    private func sampleBooking(
        id: UUID = UUID(),
        groupId: UUID = UUID(),
        slotId: UUID = UUID(),
        memberId: UUID = UUID(),
        createdAt: Date = .now
    ) -> Booking {
        Booking(
            id: id,
            groupId: groupId,
            slotId: slotId,
            memberId: memberId,
            metadata: .empty,
            createdAt: createdAt
        )
    }

    @Test("listForGroup filters + orders newest first")
    func listForGroup() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let older = sampleBooking(groupId: g1, createdAt: .now.addingTimeInterval(-3600))
        let newer = sampleBooking(groupId: g1, createdAt: .now)
        let otherGroup = sampleBooking(groupId: g2)
        let repo = MockBookingRepository(seed: [older, newer, otherGroup])

        let result = try await repo.listForGroup(g1, limit: 200)
        #expect(result.count == 2)
        #expect(result.first?.id == newer.id)
        #expect(result.last?.id == older.id)
    }

    @Test("listForSlot returns every claim against the slot")
    func listForSlot() async throws {
        let slotA = UUID()
        let slotB = UUID()
        let b1 = sampleBooking(slotId: slotA)
        let b2 = sampleBooking(slotId: slotA)
        let b3 = sampleBooking(slotId: slotB)
        let repo = MockBookingRepository(seed: [b1, b2, b3])

        let result = try await repo.listForSlot(slotA)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.slotId == slotA })
    }

    @Test("listForMember filters by booker")
    func listForMember() async throws {
        let m1 = UUID()
        let m2 = UUID()
        let b1 = sampleBooking(memberId: m1)
        let b2 = sampleBooking(memberId: m2)
        let repo = MockBookingRepository(seed: [b1, b2])

        let result = try await repo.listForMember(m1, limit: 200)
        #expect(result.count == 1)
        #expect(result.first?.memberId == m1)
    }

    @Test("get returns the booking by id")
    func getById() async throws {
        let id = UUID()
        let repo = MockBookingRepository(seed: [sampleBooking(id: id)])
        let b = try await repo.get(id)
        #expect(b.id == id)
    }

    @Test("get throws notFound on missing id")
    func getMissing() async throws {
        let repo = MockBookingRepository()
        await #expect(throws: BookingError.self) {
            _ = try await repo.get(UUID())
        }
    }

    @Test("Booking conforms to Atom protocol")
    func atomConformance() {
        // Compile-time guard: confirms the marker protocol is satisfied
        // and the SQL table name matches the migration.
        #expect(Booking.atomTableName == "bookings")
    }
}
