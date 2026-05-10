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

    @Test("setModule does not duplicate slug when re-enabling")
    func setModule_idempotentEnable() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: true,
            activeModules: ["basic_fines", "rsvp", "check_in"],
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
            activeModules: ["basic_fines", "rsvp", "check_in"],
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

    // MARK: - Cascade behaviour (mirrors mig 00057 SQL closures)

    @Test("setModule enable cascades transitive dependencies in")
    func setModule_enableCascadesDeps() async throws {
        // Empty active set + enable basic_fines should pull in rsvp + check_in.
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: false,
            activeModules: [],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: true)
        let active = Set(updated.activeModules ?? [])
        #expect(active.isSuperset(of: ["basic_fines", "rsvp", "check_in"]))
        #expect(!active.contains("rotating_host"), "enable cascade should not over-pull rotating_host")
        #expect(updated.finesEnabled == true)
    }

    @Test("setModule disable cascades transitive dependents out")
    func setModule_disableCascadesDependents() async throws {
        // Disabling rsvp should remove check_in + basic_fines + appeal_voting.
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: true,
            activeModules: ["basic_fines", "rsvp", "check_in", "appeal_voting", "rotating_host"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "rsvp", enabled: false)
        let active = Set(updated.activeModules ?? [])
        #expect(active.isDisjoint(with: ["rsvp", "check_in", "basic_fines", "appeal_voting"]))
        #expect(active.contains("rotating_host"), "disable cascade should leave unrelated rotating_host alone")
        #expect(updated.finesEnabled == false)
    }

    @Test("setModule disable basic_fines also removes appeal_voting only")
    func setModule_disableBasicFinesCascadesAppealVoting() async throws {
        let seed = Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc12345",
            finesEnabled: true,
            activeModules: ["basic_fines", "rsvp", "check_in", "appeal_voting", "rotating_host"],
            createdBy: UUID(),
            createdAt: .now
        )
        let repo = MockGroupsRepository(seed: [seed])
        let updated = try await repo.setModule(groupId: seed.id, slug: "basic_fines", enabled: false)
        let active = Set(updated.activeModules ?? [])
        #expect(!active.contains("basic_fines"))
        #expect(!active.contains("appeal_voting"), "appeal_voting depends on basic_fines and must cascade out")
        #expect(active.isSuperset(of: ["rsvp", "check_in", "rotating_host"]))
        #expect(updated.finesEnabled == false)
    }

    @Test("ModuleRegistry.v1Fallback transitive closures match server (mig 00060/00061) cascade")
    func transitiveClosures_matchSqlTables() async throws {
        // These literal expectations mirror the dependencies seeded in
        // mig 00060 and the recursive CTE cascade in mig 00061. If the
        // iOS V1Modules.swift fallback ever drifts from the server seed,
        // this test catches it before a deploy goes live.
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
