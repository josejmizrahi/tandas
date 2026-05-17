import Testing
import Foundation
import RuulCore

@Suite("MockResourceRepository")
struct ResourceRepositoryTests {
    private func sampleRow(
        groupId: UUID,
        type: ResourceType = .event,
        status: String = "scheduled"
    ) -> ResourceRow {
        ResourceRow(
            id: UUID(),
            groupId: groupId,
            resourceType: type,
            status: status,
            metadata: .empty,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @Test("list filters by group + types + statuses")
    func listFilters() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let rows = [
            sampleRow(groupId: g1, type: .event,  status: "scheduled"),
            sampleRow(groupId: g1, type: .event,  status: "completed"),
            sampleRow(groupId: g1, type: .slot,   status: "open"),
            sampleRow(groupId: g2, type: .event,  status: "scheduled")
        ]
        let repo = MockResourceRepository(seed: rows)

        let scoped = try await repo.list(
            in: g1,
            types: [.event],
            statuses: ["scheduled"],
            limit: 10
        )

        #expect(scoped.count == 1)
        #expect(scoped.first?.groupId == g1)
        #expect(scoped.first?.resourceType == .event)
        #expect(scoped.first?.status == "scheduled")
    }

    @Test("list with nil statuses returns all statuses for the requested types")
    func listAllStatuses() async throws {
        let g1 = UUID()
        let rows = [
            sampleRow(groupId: g1, status: "scheduled"),
            sampleRow(groupId: g1, status: "completed"),
            sampleRow(groupId: g1, status: "cancelled")
        ]
        let repo = MockResourceRepository(seed: rows)

        let all = try await repo.list(
            in: g1,
            types: [.event],
            statuses: nil,
            limit: 10
        )
        #expect(all.count == 3)
    }

    @Test("resource(_:) returns the row by id")
    func resourceByIdHit() async throws {
        let g1 = UUID()
        let row = sampleRow(groupId: g1)
        let repo = MockResourceRepository(seed: [row])

        let got = try await repo.resource(row.id)
        #expect(got.id == row.id)
    }

    @Test("resource(_:) throws notFound for unknown id")
    func resourceByIdMiss() async throws {
        let repo = MockResourceRepository(seed: [])

        await #expect(throws: ResourceRowError.notFound) {
            _ = try await repo.resource(UUID())
        }
    }
}
