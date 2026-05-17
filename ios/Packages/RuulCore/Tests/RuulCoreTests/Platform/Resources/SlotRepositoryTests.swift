import Testing
import Foundation
import RuulCore

@Suite("MockSlotRepository + Slot decode")
struct SlotRepositoryTests {
    private func sampleSlot(
        id: UUID = UUID(),
        groupId: UUID = UUID(),
        assetId: UUID = UUID(),
        startsAt: Date = .now,
        durationHours: Int = 2,
        status: String = "unassigned",
        archived: Bool = false
    ) -> Slot {
        let ends = startsAt.addingTimeInterval(TimeInterval(durationHours * 3600))
        return Slot(
            id: id,
            groupId: groupId,
            assetId: assetId,
            startsAt: startsAt,
            endsAt: ends,
            assignedMemberId: nil,
            bookingId: nil,
            status: status,
            createdAt: .now,
            updatedAt: .now,
            archivedAt: archived ? .now : nil
        )
    }

    @Test("listForGroup filters archived and other groups + sorts ascending")
    func listForGroupFilters() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let now = Date()
        let s1 = sampleSlot(groupId: g1, startsAt: now.addingTimeInterval(7200))
        let s2 = sampleSlot(groupId: g1, startsAt: now.addingTimeInterval(3600))
        let archived = sampleSlot(groupId: g1, startsAt: now, archived: true)
        let otherGroup = sampleSlot(groupId: g2, startsAt: now)
        let repo = MockSlotRepository(seed: [s1, s2, archived, otherGroup])

        let result = try await repo.listForGroup(g1)
        #expect(result.count == 2)
        #expect(result[0].id == s2.id)  // earlier startsAt first
        #expect(result[1].id == s1.id)
    }

    @Test("listForAsset filters by parent")
    func listForAsset() async throws {
        let assetA = UUID()
        let assetB = UUID()
        let s1 = sampleSlot(assetId: assetA)
        let s2 = sampleSlot(assetId: assetA)
        let s3 = sampleSlot(assetId: assetB)
        let repo = MockSlotRepository(seed: [s1, s2, s3])

        let result = try await repo.listForAsset(assetA)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.assetId == assetA })
    }

    @Test("get returns active slot")
    func getActive() async throws {
        let id = UUID()
        let repo = MockSlotRepository(seed: [sampleSlot(id: id)])
        let result = try await repo.get(id)
        #expect(result.id == id)
    }

    @Test("get throws notFound for archived slot")
    func getArchivedThrows() async throws {
        let id = UUID()
        let repo = MockSlotRepository(seed: [sampleSlot(id: id, archived: true)])
        await #expect(throws: SlotError.self) {
            _ = try await repo.get(id)
        }
    }

    @Test("isUnassigned + isBooked reflect lifecycle state")
    func lifecycleState() {
        let unassigned = sampleSlot(status: "unassigned")
        #expect(unassigned.isUnassigned == true)
        #expect(unassigned.isBooked == false)

        let bookingId = UUID()
        let booked = Slot(
            id: UUID(),
            groupId: UUID(),
            assetId: UUID(),
            startsAt: .now,
            endsAt: .now.addingTimeInterval(3600),
            assignedMemberId: UUID(),
            bookingId: bookingId,
            status: "booked",
            createdAt: .now,
            updatedAt: .now
        )
        #expect(booked.isBooked == true)
        #expect(booked.isUnassigned == false)
        #expect(booked.bookingId == bookingId)
    }

    @Test("ResourceRow.decodeAsSlot round-trips metadata")
    func resourceRowDecode() throws {
        let id = UUID()
        let groupId = UUID()
        let assetId = UUID()
        let assignedMemberId = UUID()
        let bookingId = UUID()
        let starts = "2026-06-01T18:00:00Z"
        let ends   = "2026-06-01T20:00:00Z"
        let row = ResourceRow(
            id: id,
            groupId: groupId,
            resourceType: .slot,
            status: "booked",
            metadata: .object([
                "asset_id":            .string(assetId.uuidString),
                "starts_at":           .string(starts),
                "ends_at":             .string(ends),
                "assigned_member_id":  .string(assignedMemberId.uuidString),
                "booking_id":          .string(bookingId.uuidString)
            ]),
            createdAt: .now,
            updatedAt: .now
        )
        let slot = try row.decodeAsSlot()
        #expect(slot.id == id)
        #expect(slot.groupId == groupId)
        #expect(slot.assetId == assetId)
        #expect(slot.assignedMemberId == assignedMemberId)
        #expect(slot.bookingId == bookingId)
        #expect(slot.status == "booked")
        #expect(slot.isBooked == true)
    }

    @Test("decodeAsSlot rejects wrong resource_type")
    func decodeWrongTypeThrows() throws {
        let row = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .space,
            status: "active",
            metadata: .object(["name": .string("oops")]),
            createdAt: .now,
            updatedAt: .now
        )
        #expect(throws: ResourceRowError.self) {
            _ = try row.decodeAsSlot()
        }
    }

    @Test("decodeAsSlot rejects missing asset_id")
    func decodeMissingAssetIdThrows() throws {
        let row = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .slot,
            status: "unassigned",
            metadata: .object([
                "starts_at": .string("2026-06-01T18:00:00Z"),
                "ends_at":   .string("2026-06-01T20:00:00Z")
            ]),
            createdAt: .now,
            updatedAt: .now
        )
        #expect(throws: ResourceRowError.self) {
            _ = try row.decodeAsSlot()
        }
    }
}
