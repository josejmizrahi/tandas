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
}

/// Slice 3 (Plans/Active/Primitives.md § 3) write-path invariants.
///
/// `MockGroupsRepository.updateConfig` mirrors the prod trigger from
/// migration 00049: active_modules is canonical, fines_enabled is
/// derived. Verifies that whichever input shape the patch carries,
/// both fields agree on commit.
@Suite("MockGroupsRepository.updateConfig SoT invariant")
struct MockGroupsRepositoryUpdateConfigInvariantTests {

    @Test("activeModules patch sets active_modules and derives fines_enabled")
    func activeModulesPatchDrivesBoth() async throws {
        let group = Self.makeGroup(activeModules: ["basic_fines", "rsvp", "check_in"], finesEnabled: true)
        let repo = MockGroupsRepository(seed: [group])

        // Drop basic_fines via activeModules patch.
        let dropFines = GroupConfigPatch(
            activeModules: group.togglingModule("basic_fines", enabled: false)
        )
        let updated = try await repo.updateConfig(groupId: group.id, patch: dropFines)
        #expect(updated.activeModules == ["rsvp", "check_in"])
        #expect(updated.finesEnabled == false)

        // Re-add basic_fines.
        let addFines = GroupConfigPatch(
            activeModules: updated.togglingModule("basic_fines", enabled: true)
        )
        let readded = try await repo.updateConfig(groupId: group.id, patch: addFines)
        #expect(readded.activeModules?.contains("basic_fines") == true)
        #expect(readded.finesEnabled == true)
    }

    @Test("legacy finesEnabled patch toggles basic_fines and derives fines_enabled")
    func legacyFinesEnabledPatchTogglesModule() async throws {
        let group = Self.makeGroup(
            activeModules: ["basic_fines", "rsvp", "check_in", "appeal_voting"],
            finesEnabled: true
        )
        let repo = MockGroupsRepository(seed: [group])

        let off = GroupConfigPatch(finesEnabled: false)
        let updated = try await repo.updateConfig(groupId: group.id, patch: off)
        #expect(updated.activeModules?.contains("basic_fines") == false)
        #expect(updated.finesEnabled == false)

        let on = GroupConfigPatch(finesEnabled: true)
        let restored = try await repo.updateConfig(groupId: group.id, patch: on)
        #expect(restored.activeModules?.contains("basic_fines") == true)
        #expect(restored.finesEnabled == true)
    }

    @Test("activeModules wins when both patch fields are set")
    func activeModulesWinsOverFinesEnabledWhenBothPresent() async throws {
        let group = Self.makeGroup(activeModules: ["basic_fines", "rsvp"], finesEnabled: true)
        let repo = MockGroupsRepository(seed: [group])

        // Conflicting patch: activeModules drops basic_fines while
        // finesEnabled=true says keep it. activeModules wins; the mock
        // (and prod trigger) derives finesEnabled from active_modules.
        let conflict = GroupConfigPatch(
            finesEnabled: true,
            activeModules: ["rsvp"]
        )
        let updated = try await repo.updateConfig(groupId: group.id, patch: conflict)
        #expect(updated.activeModules == ["rsvp"])
        #expect(updated.finesEnabled == false)
    }

    @Test("empty patch preserves both fields")
    func emptyPatchPreservesBoth() async throws {
        let group = Self.makeGroup(activeModules: ["basic_fines", "rsvp"], finesEnabled: true)
        let repo = MockGroupsRepository(seed: [group])
        let updated = try await repo.updateConfig(groupId: group.id, patch: GroupConfigPatch())
        #expect(updated.activeModules == ["basic_fines", "rsvp"])
        #expect(updated.finesEnabled == true)
    }

    private static func makeGroup(activeModules: [String], finesEnabled: Bool) -> Group {
        Group(
            id: UUID(),
            name: "Test",
            description: nil,
            inviteCode: "TEST01",
            coverImageName: nil,
            eventVocabulary: "evento",
            frequencyType: nil,
            frequencyConfig: nil,
            finesEnabled: finesEnabled,
            rotationMode: .manual,
            baseTemplate: "recurring_dinner",
            activeModules: activeModules,
            governance: nil,
            settings: nil,
            category: .socialRecurring,
            initials: "TG",
            avatarUrl: nil,
            createdBy: UUID(),
            createdAt: Date()
        )
    }
}
