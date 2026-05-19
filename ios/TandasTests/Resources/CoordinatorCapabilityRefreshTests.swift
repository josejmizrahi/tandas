import Testing
import Foundation
import RuulCore

/// Verifies `ResourceCreationCoordinator.create()` refreshes
/// `attachedCapabilities` from the injected capability repo after a
/// successful build, surfacing backend trigger-seeded caps (money,
/// custody, valuation, etc.) in the post-create intent visibility.
///
/// This closes the gap the founder cases smoke test documented in
/// case 2 (Shamiz Park Fund): pre-fix, `record_contribution` /
/// `record_expense` stayed hidden because `money` was backend-seeded
/// and the iOS resolver only saw module-provided `ledger`. Post-fix,
/// the coordinator re-reads `resource_capabilities` so both surface.
@Suite("ResourceCreationCoordinator backend cap refresh")
@MainActor
struct CoordinatorCapabilityRefreshTests {

    private func makeGroup(activeModules: [String]) -> Group {
        Group(
            id: UUID(),
            name: "T",
            inviteCode: "t",
            activeModules: activeModules,
            createdBy: UUID(),
            createdAt: .now
        )
    }

    private actor StubBuilder: ResourceBuilder {
        public nonisolated let resourceType: ResourceType
        public nonisolated let displayName: String = "Stub"
        public nonisolated let icon: String = ""
        public nonisolated let summary: String = ""
        public nonisolated let requiredFields: [BuilderField]
        public nonisolated let optionalCapabilities: [String] = []
        let fixedId: UUID

        init(resourceType: ResourceType, requiredFields: [BuilderField], fixedId: UUID = UUID()) {
            self.resourceType = resourceType
            self.requiredFields = requiredFields
            self.fixedId = fixedId
        }

        func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
            ResourceCreationResult(
                resourceId: fixedId,
                enabledCapabilityIds: draft.enabledCapabilities
            )
        }
    }

    @Test("attachedCapabilities reflects repo state when repo is injected")
    func refreshesFromRepo() async {
        let resourceId = UUID()
        // Simulate the post-backend state: the trigger seeded money +
        // ledger + status + history on the fund, even though the
        // builder only reported `ledger` (basic_fines-provided).
        let seed: [ResourceCapability] = [
            ResourceCapability(resourceId: resourceId, capabilityBlockId: "ledger",
                               config: .object([:]), enabled: true,
                               enabledAt: .now, enabledBy: nil),
            ResourceCapability(resourceId: resourceId, capabilityBlockId: "money",
                               config: .object([:]), enabled: true,
                               enabledAt: .now, enabledBy: nil),
            ResourceCapability(resourceId: resourceId, capabilityBlockId: "status",
                               config: .object([:]), enabled: true,
                               enabledAt: .now, enabledBy: nil),
            ResourceCapability(resourceId: resourceId, capabilityBlockId: "history",
                               config: .object([:]), enabled: true,
                               enabledAt: .now, enabledBy: nil)
        ]
        let repo = MockResourceCapabilityRepository(seed: seed)
        let stub = StubBuilder(
            resourceType: .fund,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)],
            fixedId: resourceId
        )
        let coord = ResourceCreationCoordinator(
            group: makeGroup(activeModules: ["basic_fines"]),
            builders: ResourceBuilderRegistry(builders: [stub]),
            capabilityRepo: repo
        )

        coord.pickType(.fund)
        coord.pickVariant(FundVariants.investmentFund)
        coord.setIdentityField("name", value: .string("Shamiz Park Fund"))
        let id = await coord.create()
        #expect(id == resourceId)

        // Pre-fix: would only contain ["ledger"] (what basic_fines
        // provides + variant attached).
        // Post-fix: should contain all 4 seeded caps.
        #expect(coord.attachedCapabilities.contains("ledger"))
        #expect(coord.attachedCapabilities.contains("money"),
                "money cap must surface from backend refresh; got \(coord.attachedCapabilities)")
        #expect(coord.attachedCapabilities.contains("status"))
        #expect(coord.attachedCapabilities.contains("history"))
    }

    @Test("falls back to builder-reported set when repo is nil")
    func fallsBackWithoutRepo() async {
        let stub = StubBuilder(
            resourceType: .fund,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)]
        )
        let coord = ResourceCreationCoordinator(
            group: makeGroup(activeModules: ["basic_fines"]),
            builders: ResourceBuilderRegistry(builders: [stub]),
            capabilityRepo: nil   // explicitly opt out
        )

        coord.pickType(.fund)
        coord.pickVariant(FundVariants.investmentFund)
        coord.setIdentityField("name", value: .string("Test"))
        _ = await coord.create()

        // Without repo, attachedCapabilities = builder.result.enabledCapabilityIds
        // = whatever the silent-attach set resolved to (ledger from
        // basic_fines + variant attached intersect).
        #expect(coord.attachedCapabilities.contains("ledger"))
        // money NOT present without repo refresh
        #expect(!coord.attachedCapabilities.contains("money"),
                "money cap not surfaced without repo refresh; honest fallback")
    }

    @Test("post-create intent visibility for fund.investment_fund now shows money intents end-to-end")
    func gapClosedForFundMoneyIntents() async {
        let resourceId = UUID()
        let seed: [ResourceCapability] = [
            ResourceCapability(resourceId: resourceId, capabilityBlockId: "ledger",
                               config: .object([:]), enabled: true,
                               enabledAt: .now, enabledBy: nil),
            ResourceCapability(resourceId: resourceId, capabilityBlockId: "money",
                               config: .object([:]), enabled: true,
                               enabledAt: .now, enabledBy: nil)
        ]
        let repo = MockResourceCapabilityRepository(seed: seed)
        let stub = StubBuilder(
            resourceType: .fund,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)],
            fixedId: resourceId
        )
        let group = makeGroup(activeModules: ["basic_fines"])
        let coord = ResourceCreationCoordinator(
            group: group,
            builders: ResourceBuilderRegistry(builders: [stub]),
            capabilityRepo: repo
        )

        coord.pickType(.fund)
        coord.pickVariant(FundVariants.investmentFund)
        coord.setIdentityField("name", value: .string("Shamiz"))
        _ = await coord.create()

        // Visibility now sees money cap (refreshed from repo).
        let visibility = IntentVisibilityResolver(
            catalog: .v1,
            resolver: CapabilityResolver(modules: .v1Fallback)
        )
        let ctx = IntentVisibilityContext(
            resourceType: .fund,
            group: group,
            attachedCapabilities: coord.attachedCapabilities,
            viewerPermissions: []
        )
        let intents = DefaultResourceIntentRegistry.v1
        let visibleIds = FundVariants.investmentFund.suggestedIntents
            .compactMap { intents.intent(id: $0) }
            .filter { visibility.isVisible($0, in: ctx) }
            .map(\.id)
        #expect(visibleIds.contains("record_contribution"),
                "aportación surfaces post-refresh; got \(visibleIds)")
        #expect(visibleIds.contains("record_expense"),
                "gasto surfaces post-refresh; got \(visibleIds)")
    }
}
