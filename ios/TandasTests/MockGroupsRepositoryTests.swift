import Testing
import Foundation
@testable import Tandas

@Suite("MockGroupsRepository")
struct MockGroupsRepositoryTests {
    @Test("listMine starts empty")
    func listEmpty() async throws {
        let repo = MockGroupsRepository()
        let groups = try await repo.listMine()
        #expect(groups.isEmpty)
    }

    @Test("create persists and listMine returns it")
    func createAndList() async throws {
        let repo = MockGroupsRepository()
        let params = CreateGroupParams(
            name: "Cena martes",
            description: nil,
            eventLabel: "Cena",
            currency: "MXN",
            groupType: .recurringDinner,
            defaultDayOfWeek: 2,
            defaultStartTime: "20:00:00",
            defaultLocation: "Casa de Jose"
        )
        let g = try await repo.create(params)
        #expect(g.name == "Cena martes")
        #expect(g.groupType == .recurringDinner)
        let all = try await repo.listMine()
        #expect(all.count == 1)
    }

    @Test("joinByCode finds preseeded group")
    func joinByCode() async throws {
        let preseed = Group(
            id: UUID(), name: "Tanda viejos", description: nil,
            groupType: .tandaSavings, inviteCode: "tandaaaa",
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [preseed])
        let g = try await repo.joinByCode("tandaaaa")
        #expect(g.id == preseed.id)
    }

    @Test("joinByCode wrong code throws")
    func joinByCodeWrong() async throws {
        let repo = MockGroupsRepository()
        await #expect(throws: GroupsError.inviteCodeNotFound) {
            _ = try await repo.joinByCode("nope0000")
        }
    }
}
