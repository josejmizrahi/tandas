import Foundation
import XCTest
import RuulCore

/// Verifies the CapabilityResolver answers match the canonical SoT
/// (`active_modules` jsonb) for the basic_fines module. Migration 00049
/// added a DB trigger + CHECK constraint guaranteeing
/// `groups.fines_enabled = ('basic_fines' = ANY(active_modules))` on every
/// row. Slice 2 migrated 5 iOS callsites from the legacy boolean to this
/// resolver. These tests guard the iOS side of the invariant — that the
/// resolver answers exactly what the trigger would compute.
///
/// See `Plans/Active/Primitives.md` § 3 for the multi-slice plan.
final class CapabilityResolverTests: XCTestCase {

    private let resolver = CapabilityResolver()

    // MARK: - basic_fines

    func test_finesEnabled_whenBasicFinesInActiveModules_returnsTrue() {
        let group = Self.makeGroup(activeModules: ["basic_fines"])
        XCTAssertTrue(resolver.finesEnabled(in: group))
    }

    func test_finesEnabled_whenBasicFinesAbsent_returnsFalse() {
        let group = Self.makeGroup(activeModules: ["rsvp", "check_in"])
        XCTAssertFalse(resolver.finesEnabled(in: group))
    }

    func test_finesEnabled_whenActiveModulesNil_usesV1Default() {
        // Legacy rows pre-migration 00019 have nil active_modules.
        // `Group.effectiveActiveModules` falls back to the V1 default
        // set, which includes "basic_fines". Resolver must agree.
        let group = Self.makeGroup(activeModules: nil)
        XCTAssertTrue(resolver.finesEnabled(in: group))
    }

    // MARK: - Cross-field invariant

    /// After migration 00049 the DB enforces
    /// `groups.fines_enabled = ('basic_fines' = ANY(active_modules))`.
    /// Whatever shape a Group arrives in to the iOS app, the resolver
    /// must agree with `effectiveActiveModules.contains("basic_fines")`.
    func test_resolverMatchesActiveModulesMembership_acrossFixtures() {
        let cases: [[String]?] = [
            nil,                                                                // legacy
            [],                                                                 // empty
            ["basic_fines"],                                                    // fines only
            ["rsvp", "check_in"],                                               // no fines
            ["basic_fines", "rotating_host", "rsvp", "check_in", "appeal_voting"], // V1 full
            ["rotating_host", "rsvp", "check_in", "appeal_voting"]              // fines off, others on
        ]
        for activeModules in cases {
            let group = Self.makeGroup(activeModules: activeModules)
            let viaResolver = resolver.finesEnabled(in: group)
            let viaMembership = group.effectiveActiveModules.contains("basic_fines")
            XCTAssertEqual(
                viaResolver,
                viaMembership,
                "Resolver disagreed with active_modules membership for \(String(describing: activeModules))"
            )
        }
    }

    // MARK: - Other module checks (sanity — no regressions from Slice 2)

    func test_appealsEnabled_requiresBothBasicFinesAndAppealVoting() {
        let onlyAppeal = Self.makeGroup(activeModules: ["appeal_voting"])
        XCTAssertFalse(resolver.appealsEnabled(in: onlyAppeal))

        let onlyFines = Self.makeGroup(activeModules: ["basic_fines"])
        XCTAssertFalse(resolver.appealsEnabled(in: onlyFines))

        let both = Self.makeGroup(activeModules: ["basic_fines", "appeal_voting"])
        XCTAssertTrue(resolver.appealsEnabled(in: both))
    }

    func test_rsvpEnabled_isolatedFromFinesFlag() {
        let group = Self.makeGroup(activeModules: ["rsvp"])
        XCTAssertTrue(resolver.rsvpEnabled(in: group))
        XCTAssertFalse(resolver.finesEnabled(in: group))
    }

    // MARK: - Helpers

    private static func makeGroup(
        activeModules: [String]?,
        finesEnabled: Bool = true
    ) -> Group {
        Group(
            id: UUID(),
            name: "Test Group",
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
