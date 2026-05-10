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
            currency: "MXN",
            timezone: "America/Mexico_City",
            baseTemplate: "recurring_dinner",
            coverImageName: nil,
            initialEventVocabulary: "cena"
        )
        let g = try await repo.create(params)
        #expect(g.name == "Cena martes")
        #expect(g.effectiveBaseTemplate == "recurring_dinner")
        #expect(g.eventVocabulary == "cena")
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

    // MARK: - setModule cascade

    @Test("setModule adds slug to active_modules")
    func setModule_addsBasicFines() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: ["rsvp", "check_in"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: true)
        #expect(updated.activeModules?.contains("basic_fines") == true)
    }

    @Test("setModule removes slug from active_modules")
    func setModule_removesBasicFines() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: ["basic_fines", "rsvp"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: false)
        #expect(updated.activeModules?.contains("basic_fines") == false)
    }

    @Test("setModule does not duplicate slug when re-enabling")
    func setModule_idempotentEnable() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: ["basic_fines", "rsvp", "check_in"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: true)
        #expect(updated.activeModules?.filter { $0 == "basic_fines" }.count == 1)
    }

    @Test("setModule on unrelated slug leaves others alone")
    func setModule_otherSlug() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: ["basic_fines", "rsvp", "check_in"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "rotating_host", enabled: true)
        #expect(updated.activeModules?.contains("rotating_host") == true)
        #expect(updated.activeModules?.contains("basic_fines") == true)
    }

    @Test("setModule unknown groupId throws .notFound")
    func setModule_unknownGroup() async throws {
        let repo = MockGroupsRepository()
        await #expect(throws: GroupsError.notFound) {
            _ = try await repo.setModule(groupId: UUID(), slug: "basic_fines", enabled: true)
        }
    }

    @Test("setModule enable cascades transitive dependencies in")
    func setModule_enableCascadesDeps() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: [],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: true)
        let active = Set(updated.activeModules ?? [])
        #expect(active.isSuperset(of: ["basic_fines", "rsvp", "check_in"]))
        #expect(!active.contains("rotating_host"))
    }

    @Test("setModule disable cascades transitive dependents out")
    func setModule_disableCascadesDependents() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: ["basic_fines", "rsvp", "check_in", "appeal_voting", "rotating_host"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "rsvp", enabled: false)
        let active = Set(updated.activeModules ?? [])
        #expect(active.isDisjoint(with: ["rsvp", "check_in", "basic_fines", "appeal_voting"]))
        #expect(active.contains("rotating_host"))
    }

    @Test("setModule disable basic_fines also removes appeal_voting only")
    func setModule_disableBasicFinesCascadesAppealVoting() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            activeModules: ["basic_fines", "rsvp", "check_in", "appeal_voting", "rotating_host"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: false)
        let active = Set(updated.activeModules ?? [])
        #expect(!active.contains("basic_fines"))
        #expect(!active.contains("appeal_voting"))
        #expect(active.isSuperset(of: ["rsvp", "check_in", "rotating_host"]))
    }

    @Test("ModuleRegistry.v1Fallback transitive closures match server cascade")
    func transitiveClosures_matchSqlTables() async throws {
        let r = ModuleRegistry.v1Fallback
        #expect(Set(r.transitiveDependencies(of: "basic_fines")) == ["rsvp", "check_in"])
        #expect(Set(r.transitiveDependencies(of: "check_in")) == ["rsvp"])
        #expect(Set(r.transitiveDependencies(of: "appeal_voting")) == ["basic_fines", "rsvp", "check_in"])
        #expect(r.transitiveDependencies(of: "rsvp").isEmpty)
        #expect(r.transitiveDependencies(of: "rotating_host").isEmpty)

        #expect(Set(r.transitiveDependents(of: "rsvp")) == ["check_in", "basic_fines", "appeal_voting"])
        #expect(Set(r.transitiveDependents(of: "check_in")) == ["basic_fines", "appeal_voting"])
        #expect(Set(r.transitiveDependents(of: "basic_fines")) == ["appeal_voting"])
        #expect(r.transitiveDependents(of: "appeal_voting").isEmpty)
        #expect(r.transitiveDependents(of: "rotating_host").isEmpty)
    }
}
