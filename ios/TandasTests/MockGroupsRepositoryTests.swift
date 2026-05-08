import Testing
import Foundation
import RuulUI
import RuulCore
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
            baseTemplate: "recurring_dinner",
            coverImageName: nil,
            defaultDayOfWeek: 2,
            defaultStartTime: "20:00:00",
            defaultLocation: "Casa de Jose"
        )
        let g = try await repo.create(params)
        #expect(g.name == "Cena martes")
        #expect(g.effectiveBaseTemplate == "recurring_dinner")
        let all = try await repo.listMine()
        #expect(all.count == 1)
    }

    @Test("joinByCode finds preseeded group")
    func joinByCode() async throws {
        let preseed = Group(
            id: UUID(),
            name: "Tanda viejos",
            description: nil,
            inviteCode: "tandaaaa",
            baseTemplate: "rotating_savings",
            category: .rotatingSavings,
            createdBy: UUID(),
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

    // MARK: - Primitives § 3 slice 3 (setModule)

    @Test("setModule adds slug + derives finesEnabled when slug is basic_fines")
    func setModule_addsBasicFines() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: false,
            activeModules: ["rsvp", "check_in"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: true)
        #expect(updated.activeModules?.contains("basic_fines") == true)
        #expect(updated.finesEnabled == true)
    }

    @Test("setModule removes slug + derives finesEnabled false")
    func setModule_removesBasicFines() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: true,
            activeModules: ["basic_fines", "rsvp"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: false)
        #expect(updated.activeModules?.contains("basic_fines") == false)
        #expect(updated.finesEnabled == false)
    }

    @Test("setModule is idempotent on already-enabled slug")
    func setModule_idempotentEnable() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: true,
            activeModules: ["basic_fines"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: true)
        #expect(updated.activeModules?.filter { $0 == "basic_fines" }.count == 1)
        #expect(updated.finesEnabled == true)
    }

    @Test("setModule on non-fines slug leaves finesEnabled untouched")
    func setModule_otherSlug_doesNotAffectFines() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: true,
            activeModules: ["basic_fines"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "rotating_host", enabled: true)
        #expect(updated.activeModules?.contains("rotating_host") == true)
        #expect(updated.finesEnabled == true)
    }

    @Test("setModule unknown groupId throws .notFound")
    func setModule_unknownGroup() async throws {
        let repo = MockGroupsRepository()
        await #expect(throws: GroupsError.notFound) {
            _ = try await repo.setModule(groupId: UUID(), slug: "basic_fines", enabled: true)
        }
    }
}
