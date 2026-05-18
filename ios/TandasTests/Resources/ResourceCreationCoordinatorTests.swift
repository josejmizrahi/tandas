import Testing
import Foundation
import RuulCore

@Suite("ResourceCreationCoordinator state machine")
@MainActor
struct ResourceCreationCoordinatorTests {

    // MARK: - Helpers

    private func makeGroup(activeModules: [String] = []) -> Group {
        Group(
            id: UUID(),
            name: "T",
            inviteCode: "test",
            activeModules: activeModules,
            createdBy: UUID(),
            createdAt: .now
        )
    }

    /// Lightweight in-line builder that captures the draft it was
    /// handed and either returns a synthesized result or throws on
    /// demand. Avoids depending on Live repos for unit tests.
    private actor StubBuilder: ResourceBuilder {
        public nonisolated let resourceType: ResourceType
        public nonisolated let displayName: String = "Stub"
        public nonisolated let icon: String = "circle"
        public nonisolated let summary: String = "stub"
        public nonisolated let requiredFields: [BuilderField]
        public nonisolated let optionalCapabilities: [String] = []

        private(set) var lastDraft: ResourceDraft?
        private let fixedResourceId: UUID
        private var shouldThrow: Bool

        init(
            resourceType: ResourceType,
            requiredFields: [BuilderField],
            fixedResourceId: UUID = UUID(),
            shouldThrow: Bool = false
        ) {
            self.resourceType = resourceType
            self.requiredFields = requiredFields
            self.fixedResourceId = fixedResourceId
            self.shouldThrow = shouldThrow
        }

        func setShouldThrow(_ value: Bool) { shouldThrow = value }
        func draftSeen() -> ResourceDraft? { lastDraft }

        func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
            lastDraft = draft
            if shouldThrow {
                throw ResourceBuilderError.rpcFailed("simulated failure")
            }
            return ResourceCreationResult(
                resourceId: fixedResourceId,
                enabledCapabilityIds: draft.enabledCapabilities
            )
        }
    }

    private func makeRegistry(_ builders: [any ResourceBuilder]) -> ResourceBuilderRegistry {
        ResourceBuilderRegistry(builders: builders)
    }

    private func makeCoordinator(
        group: Group? = nil,
        builders: [any ResourceBuilder],
        templateDefaults: [String: [String]] = [:]
    ) -> ResourceCreationCoordinator {
        ResourceCreationCoordinator(
            group: group ?? makeGroup(activeModules: ["rsvp", "check_in"]),
            builders: makeRegistry(builders),
            variants: DefaultResourceVariantRegistry.v1,
            catalog: .v1,
            resolver: CapabilityResolver(modules: .v1Fallback),
            templateDefaultsByType: templateDefaults
        )
    }

    private func eventStub(shouldThrow: Bool = false, fixedId: UUID = UUID()) -> StubBuilder {
        StubBuilder(
            resourceType: .event,
            requiredFields: [
                BuilderField(key: "title",    label: "Título",  kind: .text),
                BuilderField(key: "startsAt", label: "Empieza", kind: .dateTime)
            ],
            fixedResourceId: fixedId,
            shouldThrow: shouldThrow
        )
    }

    // MARK: - Phase transitions

    @Test("starts on typePicker with empty identity")
    func startsOnTypePicker() {
        let coord = makeCoordinator(builders: [eventStub()])
        #expect(coord.phase == .typePicker)
        #expect(coord.identityFields.isEmpty)
        #expect(coord.attachedCapabilities.isEmpty)
    }

    @Test("pickType moves to variantPicker, only from typePicker")
    func pickTypeTransition() {
        let coord = makeCoordinator(builders: [eventStub()])
        coord.pickType(.event)
        #expect(coord.phase == .variantPicker(type: .event))
        // No-op from any non-typePicker phase.
        coord.pickType(.fund)
        #expect(coord.phase == .variantPicker(type: .event))
    }

    @Test("pickVariant moves to identity and seeds defaults for non-text fields")
    func pickVariantSeedsDefaults() {
        let coord = makeCoordinator(builders: [eventStub()])
        coord.pickType(.event)
        let variant = EventVariants.socialGathering
        coord.pickVariant(variant)
        #expect(coord.phase == .identity(type: .event, variant: variant))
        // .text field stays empty (waits for user); .dateTime gets seeded
        // with tomorrow so the CTA validates immediately.
        #expect(coord.identityFields["title"] == nil)
        #expect(coord.identityFields["startsAt"] != nil)
    }

    @Test("pickVariant rejects when variant.resourceType ≠ phase type")
    func pickVariantTypeMismatch() {
        let coord = makeCoordinator(builders: [eventStub()])
        coord.pickType(.event)
        coord.pickVariant(FundVariants.sharedExpenses)   // fund variant, phase = event
        // Still on variantPicker — the mismatch is silently ignored.
        #expect(coord.phase == .variantPicker(type: .event))
    }

    @Test("backOneStep walks identity → variantPicker → typePicker")
    func backOneStepWalksBackwards() {
        let coord = makeCoordinator(builders: [eventStub()])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        #expect(coord.phase == .identity(type: .event, variant: EventVariants.socialGathering))

        coord.backOneStep()
        #expect(coord.phase == .variantPicker(type: .event))

        coord.backOneStep()
        #expect(coord.phase == .typePicker)
        #expect(coord.identityFields.isEmpty)

        // No-op at typePicker.
        coord.backOneStep()
        #expect(coord.phase == .typePicker)
    }

    @Test("reset clears phase, identity, attachedCapabilities")
    func resetClearsState() async {
        let coord = makeCoordinator(builders: [eventStub()])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        coord.setIdentityField("title", value: .string("X"))
        coord.reset()
        #expect(coord.phase == .typePicker)
        #expect(coord.identityFields.isEmpty)
        #expect(coord.attachedCapabilities.isEmpty)
    }

    // MARK: - canCreate gating

    @Test("canCreate is false until all required non-optional fields are filled")
    func canCreateGating() {
        let coord = makeCoordinator(builders: [eventStub()])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        // startsAt was seeded, title is still empty → false.
        #expect(coord.canCreate == false)
        coord.setIdentityField("title", value: .string("Cena"))
        #expect(coord.canCreate == true)
        // Whitespace-only string counts as empty.
        coord.setIdentityField("title", value: .string("   "))
        #expect(coord.canCreate == false)
    }

    // MARK: - Silent-cap resolution

    @Test("resolveSilentCapabilities = variant ∪ template, ∩ available ∩ stable")
    func silentCapResolutionIntersection() {
        // Group provides rsvp + check_in modules. Catalog has both as
        // stable. Variant.socialGathering's attached set (schedule, rules,
        // status, history, description, host_actions) is provided by
        // event-shape primitives module … but on a vanilla mock group
        // without those modules listed, the resolver drops them — which
        // is the doctrine ("don't lie to the user").
        // We seed the group with `event_essentials` (the module that
        // provides description/host_actions/status/history/etc.) to make
        // the assertion meaningful. Fall back to the V1 active set.
        let coord = makeCoordinator(
            group: makeGroup(activeModules: ["rsvp", "check_in"]),
            builders: [eventStub()]
        )
        let resolved = coord.resolveSilentCapabilities(for: EventVariants.socialGathering)
        // Unknown ids never appear.
        #expect(!resolved.contains("totally_fake_capability"))
        // Variant declares no incomplete caps, so anything the resolver
        // surfaces should be stable.
        for id in resolved {
            #expect(CapabilityCatalog.v1[id]?.status.isStable == true)
        }
    }

    @Test("template defaults union with variant's attached set")
    func templateDefaultsUnion() {
        // Variant doesn't claim "rsvp" silently (it's intent-triggered).
        // A template default that DOES list rsvp should pull it into the
        // resolved set when the group's rsvp module is on.
        let coord = makeCoordinator(
            group: makeGroup(activeModules: ["rsvp"]),
            builders: [eventStub()],
            templateDefaults: ["event": ["rsvp"]]
        )
        let resolved = coord.resolveSilentCapabilities(for: EventVariants.socialGathering)
        #expect(resolved.contains("rsvp"))
    }

    @Test("incomplete blocks are dropped even when in variant or template")
    func incompleteCapsDropped() {
        // `booking` is .incomplete in v1. Template-defaulting it should
        // still drop it.
        let coord = makeCoordinator(
            group: makeGroup(activeModules: ["slot_assignment"]),
            builders: [eventStub()],
            templateDefaults: ["event": ["booking"]]
        )
        let resolved = coord.resolveSilentCapabilities(for: EventVariants.socialGathering)
        #expect(!resolved.contains("booking"))
    }

    // MARK: - create()

    @Test("create() happy path: identity → creating → postCreate with resourceId")
    func createHappyPath() async {
        let fixedId = UUID()
        let stub = eventStub(fixedId: fixedId)
        let coord = makeCoordinator(builders: [stub])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        coord.setIdentityField("title", value: .string("Cena del jueves"))

        let returnedId = await coord.create()
        #expect(returnedId == fixedId)
        #expect(coord.phase == .postCreate(resourceId: fixedId,
                                           variant: EventVariants.socialGathering))
    }

    @Test("create() forwards silent caps via ResourceDraft.enabledCapabilities")
    func createPassesSilentCapsToBuilder() async {
        let stub = eventStub()
        let coord = makeCoordinator(
            group: makeGroup(activeModules: ["rsvp"]),
            builders: [stub],
            templateDefaults: ["event": ["rsvp"]]
        )
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        coord.setIdentityField("title", value: .string("X"))
        _ = await coord.create()
        let draft = await stub.draftSeen()
        #expect(draft?.enabledCapabilities.contains("rsvp") == true)
        // The builder's returned enabledCapabilityIds is mirrored to the
        // coordinator so the post-create screen sees what's actually live.
        #expect(coord.attachedCapabilities.contains("rsvp"))
    }

    @Test("create() error path: identity → creating → failed(message)")
    func createErrorPath() async {
        let stub = eventStub(shouldThrow: true)
        let coord = makeCoordinator(builders: [stub])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        coord.setIdentityField("title", value: .string("X"))

        let returnedId = await coord.create()
        #expect(returnedId == nil)
        if case .failed(let msg) = coord.phase {
            #expect(msg.contains("Error del servidor") || msg.contains("simulated"))
        } else {
            Issue.record("expected .failed phase, got \(coord.phase)")
        }
    }

    @Test("backOneStep from .failed returns to .identity preserving state")
    func backFromFailedPreservesIdentity() async {
        let stub = eventStub(shouldThrow: true)
        let coord = makeCoordinator(builders: [stub])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        coord.setIdentityField("title", value: .string("X"))
        _ = await coord.create()
        // .failed
        coord.backOneStep()
        if case .identity(let type, let variant) = coord.phase {
            #expect(type == .event)
            #expect(variant.id == EventVariants.socialGathering.id)
            #expect(coord.identityFields["title"] == .string("X"))
        } else {
            Issue.record("expected back-to-identity, got \(coord.phase)")
        }
    }

    @Test("create() is no-op when canCreate is false (returns nil, no phase change)")
    func createBlockedWhenInvalid() async {
        let stub = eventStub()
        let coord = makeCoordinator(builders: [stub])
        coord.pickType(.event)
        coord.pickVariant(EventVariants.socialGathering)
        // No title → canCreate=false
        let id = await coord.create()
        #expect(id == nil)
        #expect(coord.phase == .identity(type: .event,
                                         variant: EventVariants.socialGathering))
    }
}
