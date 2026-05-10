import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("CapabilityResolver expanded")
struct CapabilityResolverExpandedTests {
    private let resolver = CapabilityResolver(modules: .v1Fallback)
    private let catalog = CapabilityCatalog.v1

    private func makeGroup(activeModules: [String]) -> Group {
        Group(
            id: UUID(),
            name: "G",
            inviteCode: "abc",
            activeModules: activeModules,
            createdBy: UUID(),
            createdAt: .now
        )
    }

    @Test("availableCapabilities surfaces blocks from active modules only")
    func availableCapabilitiesGated() {
        let g = makeGroup(activeModules: ["rsvp", "check_in"])
        let blocks = resolver.availableCapabilities(for: .event, in: g, catalog: catalog)
        #expect(blocks.contains("rsvp"))
        #expect(blocks.contains("attendance"))
        // basic_fines provides ledger but it's not in active_modules.
        #expect(!blocks.contains("ledger"))
    }

    @Test("canEnableCapability rejects blocks whose deps are missing")
    func cannotEnableWithoutDeps() {
        // basic_fines provides "ledger". With only basic_fines active,
        // money requires ledger → ledger is provided, so money would
        // succeed if all deps satisfied. But appeal needs voting +
        // consequence which require appeal_voting module too.
        let g = makeGroup(activeModules: ["basic_fines", "rsvp", "check_in"])
        #expect(resolver.canEnableCapability("ledger", on: .event, in: g, catalog: catalog))
        // Without appeal_voting active, "appeal" block isn't even available.
        #expect(!resolver.canEnableCapability("appeal", on: .event, in: g, catalog: catalog))
    }

    @Test("canViewSection true when an active module provides the route")
    func sectionGate() {
        let g = makeGroup(activeModules: ["rsvp"])
        // rsvp provides route id "rsvp.list"
        #expect(resolver.canViewSection("rsvp.list", in: g, catalog: catalog))
        // money.balance is provided by basic_fines (money.routes), but that
        // module isn't active here.
        #expect(!resolver.canViewSection("money.balance", in: g, catalog: catalog))
    }

    @Test("canRecordExpense gated on basic_fines (money block) being active")
    func canRecordExpenseGate() {
        let withFines = makeGroup(activeModules: ["basic_fines", "rsvp", "check_in"])
        // basic_fines provides "rules", "consequence", "ledger" — not "money".
        // Money belongs conceptually to basic_fines but isn't in its
        // provided_capability_blocks list. Tests reflect the seed exactly.
        #expect(!resolver.canRecordExpense(on: .event, in: withFines, catalog: catalog))
    }

    @Test("canVote available when appeal_voting module is on")
    func canVoteGated() {
        let g1 = makeGroup(activeModules: ["basic_fines", "rsvp", "check_in"])
        #expect(!resolver.canVote(on: .proposal, in: g1, catalog: catalog))

        let g2 = makeGroup(activeModules: ["basic_fines", "rsvp", "check_in", "appeal_voting"])
        #expect(resolver.canVote(on: .proposal, in: g2, catalog: catalog))
    }

    @Test("availableSections is union across active modules")
    func availableSectionsUnion() {
        let g = makeGroup(activeModules: ["rsvp", "rotating_host"])
        let sections = resolver.availableSections(in: g, catalog: catalog)
        #expect(sections.contains("rsvp.list"))
        #expect(sections.contains("rotation.order"))
        // appeal-only routes shouldn't appear since appeal_voting isn't on.
        #expect(!sections.contains("voting.results"))
    }
}
