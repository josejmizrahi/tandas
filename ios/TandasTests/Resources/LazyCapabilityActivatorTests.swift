import Testing
import Foundation
import RuulCore

@Suite("LazyCapabilityActivator")
struct LazyCapabilityActivatorTests {
    private let catalog = CapabilityCatalog.v1
    private let resolver = CapabilityResolver(modules: .v1Fallback)

    private func makeGroup(activeModules: [String]) -> Group {
        Group(
            id: UUID(),
            name: "Test",
            inviteCode: "test",
            activeModules: activeModules,
            createdBy: UUID(),
            createdAt: .now
        )
    }

    @Test("Unknown ids are skipped to skippedUnknown")
    func unknownCapabilitiesSkipped() async {
        let repo = MockResourceCapabilityRepository()
        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        let group = makeGroup(activeModules: ["rsvp"])
        let outcome = await activator.ensure(
            ["totally_fake_block_id"],
            on: UUID(), resourceType: .event, in: group
        )
        #expect(outcome.skippedUnknown.contains("totally_fake_block_id"))
        #expect(outcome.attached.isEmpty)
    }

    @Test("Incomplete-status blocks are skipped to skippedIncomplete")
    func incompleteCapsSkipped() async {
        // `booking` ships as .incomplete in v1 catalog.
        let repo = MockResourceCapabilityRepository()
        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        // Even with a group that nominally provides booking via a module,
        // .incomplete status hides it from the activator.
        let group = makeGroup(activeModules: ["slot_assignment"])
        let outcome = await activator.ensure(
            ["booking"],
            on: UUID(), resourceType: .slot, in: group
        )
        #expect(outcome.skippedIncomplete.contains("booking"))
        #expect(!outcome.attached.contains("booking"))
    }

    @Test("Blocks not provided by active modules are skipped to skippedUnavailable")
    func unavailableCapsSkipped() async {
        // RSVP module isn't active → rsvp cap is unavailable for the group.
        let repo = MockResourceCapabilityRepository()
        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        let group = makeGroup(activeModules: ["check_in"])
        let outcome = await activator.ensure(
            ["rsvp"],
            on: UUID(), resourceType: .event, in: group
        )
        #expect(outcome.skippedUnavailable.contains("rsvp"))
        #expect(outcome.attached.isEmpty)
    }

    @Test("Available + stable + missing cap is attached and surfaced as attached")
    func attachesStableAvailable() async {
        let repo = MockResourceCapabilityRepository()
        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        let group = makeGroup(activeModules: ["rsvp"])
        let resourceId = UUID()
        let outcome = await activator.ensure(
            ["rsvp"],
            on: resourceId, resourceType: .event, in: group
        )
        #expect(outcome.attached.contains("rsvp"))
        let rows = try? await repo.list(resourceId: resourceId)
        #expect(rows?.contains { $0.capabilityBlockId == "rsvp" && $0.enabled } == true)
    }

    @Test("Idempotent: already-enabled caps land in alreadyAttached, not attached")
    func idempotent() async {
        let resourceId = UUID()
        let repo = MockResourceCapabilityRepository()
        // Seed the cap as already enabled.
        _ = try? await repo.enable("rsvp", on: resourceId, config: .object([:]))

        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        let group = makeGroup(activeModules: ["rsvp"])
        let outcome = await activator.ensure(
            ["rsvp"],
            on: resourceId, resourceType: .event, in: group
        )
        #expect(outcome.alreadyAttached.contains("rsvp"))
        #expect(!outcome.attached.contains("rsvp"))
    }

    @Test("Empty input returns empty outcome")
    func emptyInput() async {
        let repo = MockResourceCapabilityRepository()
        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        let group = makeGroup(activeModules: ["rsvp"])
        let outcome = await activator.ensure(
            [], on: UUID(), resourceType: .event, in: group
        )
        #expect(outcome.attached.isEmpty)
        #expect(outcome.alreadyAttached.isEmpty)
        #expect(outcome.skippedUnknown.isEmpty)
        #expect(outcome.skippedIncomplete.isEmpty)
        #expect(outcome.skippedUnavailable.isEmpty)
        #expect(outcome.failed.isEmpty)
    }

    @Test("Mixed batch sorts caps into the right buckets in one call")
    func mixedBatch() async {
        let repo = MockResourceCapabilityRepository()
        let activator = LazyCapabilityActivator(
            catalog: catalog, resolver: resolver, capabilityRepo: repo
        )
        let group = makeGroup(activeModules: ["rsvp"])
        let outcome = await activator.ensure(
            ["rsvp",              // stable + available → attached
             "booking",           // .incomplete → skipped
             "totally_fake",      // unknown → skipped
             "check_in"],         // stable but module not active → unavailable
            on: UUID(), resourceType: .event, in: group
        )
        #expect(outcome.attached.contains("rsvp"))
        #expect(outcome.skippedIncomplete.contains("booking"))
        #expect(outcome.skippedUnknown.contains("totally_fake"))
        #expect(outcome.skippedUnavailable.contains("check_in"))
    }
}
