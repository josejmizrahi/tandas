import Testing
import Foundation
import RuulCore

@Suite("MockSpaceRepository")
struct SpaceRepositoryTests {
    private func sampleSpace(
        id: UUID = UUID(),
        groupId: UUID = UUID(),
        name: String = "Salón comunitario",
        capacity: Int? = 50,
        archived: Bool = false
    ) -> Space {
        Space(
            id: id,
            groupId: groupId,
            name: name,
            capacity: capacity,
            locationName: "Av. Reforma 222",
            locationLat: 19.4326,
            locationLng: -99.1332,
            description: nil,
            status: "active",
            createdAt: .now,
            updatedAt: .now,
            archivedAt: archived ? .now : nil
        )
    }

    @Test("listForGroup filters archived and other groups")
    func listFilters() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let active1 = sampleSpace(groupId: g1, name: "Cancha")
        let active2 = sampleSpace(groupId: g1, name: "Salón")
        let archived = sampleSpace(groupId: g1, name: "Vieja oficina", archived: true)
        let otherGroup = sampleSpace(groupId: g2, name: "Bodega")
        let repo = MockSpaceRepository(seed: [active1, active2, archived, otherGroup])

        let result = try await repo.listForGroup(g1)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.groupId == g1 && $0.archivedAt == nil })
        #expect(result.contains { $0.name == "Cancha" })
        #expect(result.contains { $0.name == "Salón" })
    }

    @Test("get returns the matching active space")
    func getActive() async throws {
        let id = UUID()
        let repo = MockSpaceRepository(seed: [sampleSpace(id: id)])
        let result = try await repo.get(id)
        #expect(result.id == id)
    }

    @Test("get throws notFound for archived spaces")
    func getArchivedThrows() async throws {
        let id = UUID()
        let repo = MockSpaceRepository(seed: [sampleSpace(id: id, archived: true)])
        await #expect(throws: SpaceError.self) {
            _ = try await repo.get(id)
        }
    }

    @Test("create persists and is retrievable")
    func createPersists() async throws {
        let groupId = UUID()
        let repo = MockSpaceRepository()
        let newId = try await repo.create(
            groupId: groupId,
            name: "Sala de juntas",
            capacity: 20,
            locationName: "Piso 4",
            locationLat: nil,
            locationLng: nil,
            description: "Para sesiones de admin"
        )
        let fetched = try await repo.get(newId)
        #expect(fetched.name == "Sala de juntas")
        #expect(fetched.capacity == 20)
        #expect(fetched.locationName == "Piso 4")
        #expect(fetched.description == "Para sesiones de admin")
        #expect(fetched.groupId == groupId)
    }

    @Test("create rejects empty name")
    func createRejectsEmptyName() async throws {
        let repo = MockSpaceRepository()
        await #expect(throws: SpaceError.self) {
            _ = try await repo.create(
                groupId: UUID(),
                name: "   ",
                capacity: nil,
                locationName: nil,
                locationLat: nil,
                locationLng: nil,
                description: nil
            )
        }
    }

    @Test("ResourceRow.decodeAsSpace round-trips metadata")
    func resourceRowDecode() throws {
        let id = UUID()
        let groupId = UUID()
        let row = ResourceRow(
            id: id,
            groupId: groupId,
            resourceType: .space,
            status: "active",
            metadata: .object([
                "name": .string("Cancha de tenis"),
                "capacity": .int(8),
                "location_name": .string("Club deportivo"),
                "location_lat": .double(19.42),
                "location_lng": .double(-99.13),
                "description": .string("Reservas mín 1h")
            ]),
            createdAt: .now,
            updatedAt: .now
        )
        let space = try row.decodeAsSpace()
        #expect(space.id == id)
        #expect(space.groupId == groupId)
        #expect(space.name == "Cancha de tenis")
        #expect(space.capacity == 8)
        #expect(space.locationName == "Club deportivo")
        #expect(space.locationLat == 19.42)
        #expect(space.locationLng == -99.13)
        #expect(space.description == "Reservas mín 1h")
    }

    @Test("decodeAsSpace rejects wrong resource_type")
    func decodeWrongTypeThrows() throws {
        let row = ResourceRow(
            id: UUID(),
            groupId: UUID(),
            resourceType: .event,
            status: "scheduled",
            metadata: .object(["name": .string("oops")]),
            createdAt: .now,
            updatedAt: .now
        )
        #expect(throws: ResourceRowError.self) {
            _ = try row.decodeAsSpace()
        }
    }
}
