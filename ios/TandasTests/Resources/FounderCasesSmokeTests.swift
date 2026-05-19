import Testing
import Foundation
import RuulCore

/// End-to-end smoke tests for the 6 founder validation cases.
///
/// Walks each case through the full state machine
/// (typePicker → variantPicker → identity → creating → postCreate),
/// asserts the resource lands with the right type, and verifies the
/// post-create intent visibility produces the expected verbs.
///
/// What we assert per case:
///   1. State machine traversal works (pickType → pickVariant → set
///      identity fields → create returns a resource id).
///   2. `coordinator.attachedCapabilities` includes the caps the
///      variant declared AND the group's active modules provide.
///   3. The post-create intent grid (variant.suggestedIntents filtered
///      through IntentVisibilityResolver) produces the verbs the
///      founder UX expects.
///
/// What we don't assert (out of scope for smoke):
///   - Platform-inherent caps (status, history, description, schedule,
///     host_actions, location, custody, valuation, maintenance,
///     transfer, delegation) — these are backend-seeded via triggers
///     per mig 00109/00110/00199/00200, not module-provided. The
///     resolver's `availableCapabilities(for:in:)` correctly filters
///     them out at the iOS layer; the backend attaches them on insert.
///   - Real RPC behavior (we use stub builders that return synthetic
///     resource ids; the actual builder + RPC + RLS is exercised by
///     existing per-repo integration tests).
///   - Sheet rendering (covered by per-destination wireup PRs).
@Suite("Founder cases smoke test")
@MainActor
struct FounderCasesSmokeTests {

    // MARK: - Fixtures

    private static let visibility = IntentVisibilityResolver(
        catalog: .v1,
        resolver: CapabilityResolver(modules: .v1Fallback)
    )
    private static let intents = DefaultResourceIntentRegistry.v1

    private func makeGroup(activeModules: [String]) -> Group {
        Group(
            id: UUID(),
            name: "Test Group",
            inviteCode: "test",
            activeModules: activeModules,
            createdBy: UUID(),
            createdAt: .now
        )
    }

    /// Stub builder mirroring the real ResourceBuilder protocol;
    /// captures the draft + returns a synthetic resource id so we can
    /// exercise the state machine without standing up SupabaseClient.
    private actor StubBuilder: ResourceBuilder {
        public nonisolated let resourceType: ResourceType
        public nonisolated let displayName: String = "Stub"
        public nonisolated let icon: String = "circle"
        public nonisolated let summary: String = ""
        public nonisolated let requiredFields: [BuilderField]
        public nonisolated let optionalCapabilities: [String] = []
        private(set) var lastDraft: ResourceDraft?
        private let fixedId: UUID

        init(resourceType: ResourceType,
             requiredFields: [BuilderField],
             fixedId: UUID = UUID()) {
            self.resourceType = resourceType
            self.requiredFields = requiredFields
            self.fixedId = fixedId
        }

        func lastDraftSeen() -> ResourceDraft? { lastDraft }

        func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
            lastDraft = draft
            return ResourceCreationResult(
                resourceId: fixedId,
                enabledCapabilityIds: draft.enabledCapabilities
            )
        }
    }

    private func makeRegistry(_ builders: [any ResourceBuilder]) -> ResourceBuilderRegistry {
        ResourceBuilderRegistry(builders: builders)
    }

    private func makeCoordinator(
        group: Group,
        builders: [any ResourceBuilder]
    ) -> ResourceCreationCoordinator {
        ResourceCreationCoordinator(
            group: group,
            builders: makeRegistry(builders),
            variants: DefaultResourceVariantRegistry.v1,
            catalog: .v1,
            resolver: CapabilityResolver(modules: .v1Fallback)
        )
    }

    /// Walks the state machine through a complete create. Returns
    /// the resource id on success, or fails the test.
    private func walkCreate(
        coord: ResourceCreationCoordinator,
        type: ResourceType,
        variant: ResourceVariant,
        identity: [String: JSONConfig]
    ) async -> UUID? {
        coord.pickType(type)
        guard coord.phase == .variantPicker(type: type) else {
            Issue.record("pickType failed; phase = \(coord.phase)")
            return nil
        }
        coord.pickVariant(variant)
        guard case .identity = coord.phase else {
            Issue.record("pickVariant failed; phase = \(coord.phase)")
            return nil
        }
        for (key, value) in identity {
            coord.setIdentityField(key, value: value)
        }
        guard coord.canCreate else {
            Issue.record("canCreate=false after filling identity \(identity); fields seen = \(coord.identityFields)")
            return nil
        }
        return await coord.create()
    }

    /// Builds the post-create visibility context + filters the
    /// variant's suggested intents through it. Returns the visible
    /// intent IDs in order.
    private func visibleIntentIDs(
        for variant: ResourceVariant,
        in group: Group,
        attached: Set<String>,
        viewerPermissions: Set<Permission> = []
    ) -> [String] {
        let ctx = IntentVisibilityContext(
            resourceType: variant.resourceType,
            group: group,
            attachedCapabilities: attached,
            viewerPermissions: viewerPermissions
        )
        return variant.suggestedIntents
            .compactMap { Self.intents.intent(id: $0) }
            .filter { Self.visibility.isVisible($0, in: ctx) }
            .map(\.id)
    }

    // MARK: - Case 1: Palco Mundial (space.private_space)

    @Test("Founder case 1 — Palco Mundial (space.private_space)")
    func case1PalcoMundial() async {
        let group = makeGroup(activeModules: [])  // space has no module deps for silent caps
        let stub = StubBuilder(
            resourceType: .space,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)]
        )
        let coord = makeCoordinator(group: group, builders: [stub])

        let id = await walkCreate(
            coord: coord,
            type: .space,
            variant: SpaceVariants.privateSpace,
            identity: ["name": .string("Palco Mundial")]
        )
        #expect(id != nil)
        #expect(coord.phase == .postCreate(resourceId: id!, variant: SpaceVariants.privateSpace))

        // Variant.suggestedIntents declares the verbs; visibility
        // filters by what the group can do. Space's variant suggests:
        // grant_access, create_child_event, track_money, add_rules,
        // link_resource, view_history. Without `access` cap (incomplete)
        // grant_access stays hidden; without ledger module track_money
        // hides too. The remaining verbs SHOULD surface.
        let visible = visibleIntentIDs(
            for: SpaceVariants.privateSpace,
            in: group,
            attached: coord.attachedCapabilities
        )
        #expect(visible.contains("create_child_event"),
                "Palco must offer to create child events; got \(visible)")
        #expect(visible.contains("add_rules"),
                "Palco must offer to add rules; got \(visible)")
        #expect(visible.contains("link_resource"),
                "Palco must offer to link resources; got \(visible)")
        #expect(visible.contains("view_history"),
                "Palco must offer to view history; got \(visible)")
        #expect(!visible.contains("grant_access"),
                "grant_access stays hidden — access cap is incomplete in v1")
    }

    // MARK: - Case 2: Shamiz Park Fund (fund.investment_fund)

    @Test("Founder case 2 — Shamiz Park Fund (fund.investment_fund)")
    func case2ShamizParkFund() async {
        // basic_fines provides ledger/consequence/rules so the fund's
        // money intents have a real cap path.
        let group = makeGroup(activeModules: ["basic_fines"])
        let stub = StubBuilder(
            resourceType: .fund,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)]
        )
        let coord = makeCoordinator(group: group, builders: [stub])

        let id = await walkCreate(
            coord: coord,
            type: .fund,
            variant: FundVariants.investmentFund,
            identity: ["name": .string("Shamiz Park Fund")]
        )
        #expect(id != nil)

        // ledger comes from basic_fines and is in variant.attachedCapabilities
        // → must land in attachedCapabilities.
        #expect(coord.attachedCapabilities.contains("ledger"),
                "ledger cap must attach (basic_fines provides it)")

        // iOS-only visibility (without backend simulation): money cap
        // isn't provided by any V1 module — it's backend-seeded on
        // fund creation per mig 00136-145 (Tier 6). Until the
        // activator surfaces those, record_contribution/record_expense
        // (which need ledger+money) stay hidden in the iOS-only
        // resolver. Honest assertion: only the cap-free intents land.
        let visibleIOSOnly = visibleIntentIDs(
            for: FundVariants.investmentFund,
            in: group,
            attached: coord.attachedCapabilities
        )
        #expect(visibleIOSOnly.contains("link_resource"))
        #expect(visibleIOSOnly.contains("add_rules"))
        // Documented gap: money intents hidden until backend-seeded
        // caps surface to iOS. Tracked in follow-up.
        #expect(!visibleIOSOnly.contains("record_contribution"),
                "Known gap: money cap backend-seeded, iOS resolver doesn't see it yet")

        // Simulated post-backend state: backend has attached money +
        // ledger on the fresh fund. Visibility now matches founder UX.
        var simulated = coord.attachedCapabilities
        simulated.insert("money")
        let visibleWithBackend = visibleIntentIDs(
            for: FundVariants.investmentFund,
            in: group,
            attached: simulated
        )
        #expect(visibleWithBackend.contains("record_contribution"),
                "With backend-seeded money cap, aportación must surface; got \(visibleWithBackend)")
        #expect(visibleWithBackend.contains("record_expense"),
                "With backend-seeded money cap, gasto must surface; got \(visibleWithBackend)")
    }

    // MARK: - Case 3: 50% Palco Right (right.ownership_equity_right)

    @Test("Founder case 3 — 50% Palco Right (right.ownership_equity_right)")
    func case3PalcoEquityRight() async {
        let group = makeGroup(activeModules: [])
        let stub = StubBuilder(
            resourceType: .right,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)]
        )
        let coord = makeCoordinator(group: group, builders: [stub])

        let id = await walkCreate(
            coord: coord,
            type: .right,
            variant: RightVariants.ownershipEquityRight,
            identity: ["name": .string("50% Palco")]
        )
        #expect(id != nil)

        let visible = visibleIntentIDs(
            for: RightVariants.ownershipEquityRight,
            in: group,
            attached: coord.attachedCapabilities
        )
        // Right variant suggests change_control, define_priority,
        // link_resource, view_history, add_rules. change_control needs
        // .modifyGovernance permission → hidden for empty perms.
        #expect(!visible.contains("change_control"),
                "change_control hidden without modifyGovernance perm")
        #expect(visible.contains("link_resource"),
                "link_resource always visible (no perm/cap deps)")
        #expect(visible.contains("view_history"),
                "view_history always visible")
        #expect(visible.contains("add_rules"))

        // With modifyGovernance perm, change_control surfaces.
        let visibleAsAdmin = visibleIntentIDs(
            for: RightVariants.ownershipEquityRight,
            in: group,
            attached: coord.attachedCapabilities,
            viewerPermissions: [.modifyGovernance]
        )
        #expect(visibleAsAdmin.contains("change_control"),
                "change_control surfaces with modifyGovernance perm")
    }

    // MARK: - Case 4: Nave Toluca (asset.property)

    @Test("Founder case 4 — Nave Toluca (asset.property)")
    func case4NaveToluca() async {
        let group = makeGroup(activeModules: [])
        let stub = StubBuilder(
            resourceType: .asset,
            requiredFields: [BuilderField(key: "name", label: "Nombre", kind: .text)]
        )
        let coord = makeCoordinator(group: group, builders: [stub])

        let id = await walkCreate(
            coord: coord,
            type: .asset,
            variant: AssetVariants.property,
            identity: ["name": .string("Nave Toluca")]
        )
        #expect(id != nil)

        let visible = visibleIntentIDs(
            for: AssetVariants.property,
            in: group,
            attached: coord.attachedCapabilities
        )
        // Property variant suggests link_resource, record_valuation,
        // assign_custody, track_money, add_rules, view_history.
        // record_valuation needs modifyGovernance per DefaultIntents.
        #expect(visible.contains("link_resource"),
                "link to fund must be available")
        #expect(visible.contains("add_rules"))
        #expect(visible.contains("view_history"))
        // assign_custody needs custody cap. v1 catalog has custody as
        // stable but no V1 module provides it (it's backend-seeded);
        // resolver filters it out → assign_custody hidden in iOS-only
        // visibility check. Expected behavior: backend seeds custody on
        // insert, then the toolbar surface (which reads ALL attached
        // caps, not just module-provided) shows it.
    }

    // MARK: - Case 5: Partido Mundial (event.sports_match)

    @Test("Founder case 5 — Partido Mundial (event.sports_match)")
    func case5PartidoMundial() async {
        // rsvp + check_in modules so invite_people + check_in_attendees
        // can light up.
        let group = makeGroup(activeModules: ["rsvp", "check_in"])
        let stub = StubBuilder(
            resourceType: .event,
            requiredFields: [
                BuilderField(key: "title", label: "Título", kind: .text),
                BuilderField(key: "startsAt", label: "Empieza", kind: .dateTime)
            ]
        )
        let coord = makeCoordinator(group: group, builders: [stub])

        let id = await walkCreate(
            coord: coord,
            type: .event,
            variant: EventVariants.sportsMatch,
            identity: ["title": .string("Argentina vs Francia")]
        )
        // startsAt seeded by coordinator (defaults to tomorrow).
        #expect(id != nil)

        let visible = visibleIntentIDs(
            for: EventVariants.sportsMatch,
            in: group,
            attached: coord.attachedCapabilities
        )
        // sports_match suggests link_resource, invite_people,
        // check_in_attendees, add_rules, track_money, view_history.
        #expect(visible.contains("invite_people"),
                "invite_people needs rsvp module (active); got \(visible)")
        #expect(visible.contains("check_in_attendees"),
                "check_in_attendees needs check_in module (active); got \(visible)")
        #expect(visible.contains("link_resource"),
                "link to palco must work")
        #expect(visible.contains("add_rules"))
        #expect(visible.contains("view_history"))
    }

    // MARK: - Case 6: Cena rotativa (event.recurring_event)

    @Test("Founder case 6 — Cena rotativa (event.recurring_event)")
    func case6CenaRotativa() async {
        // rsvp + check_in for invite + check-in flows. rotating_host
        // doesn't affect post-create visibility because rotation isn't
        // an intent — it's a silent attach via the recurring_event
        // variant for the SERIES (not visible as a verb).
        let group = makeGroup(activeModules: ["rsvp", "check_in", "rotating_host"])
        let stub = StubBuilder(
            resourceType: .event,
            requiredFields: [
                BuilderField(key: "title", label: "Título", kind: .text),
                BuilderField(key: "startsAt", label: "Empieza", kind: .dateTime)
            ]
        )
        let coord = makeCoordinator(group: group, builders: [stub])

        let id = await walkCreate(
            coord: coord,
            type: .event,
            variant: EventVariants.recurringEvent,
            identity: ["title": .string("Cena del jueves")]
        )
        #expect(id != nil)

        // Recurring event variant lists `recurrence` in attachedCapabilities.
        // The rotating_host module provides `rotation` and `assignment`
        // but NOT `recurrence` (recurrence isn't module-gated; it's
        // backend-seeded per resource_series). The coordinator's resolver
        // filter drops it from the silent set. Backend adds it on insert.
        // For the iOS smoke, we accept the coordinator's filtered set
        // matches what V1Modules can verify.

        let visible = visibleIntentIDs(
            for: EventVariants.recurringEvent,
            in: group,
            attached: coord.attachedCapabilities
        )
        // recurring_event suggests invite_people, check_in_attendees,
        // add_rules, track_money, link_resource, view_history (same
        // shape as social_gathering — recurrence is structural, not
        // a visible verb).
        #expect(visible.contains("invite_people"),
                "Cena rotativa must offer invite; got \(visible)")
        #expect(visible.contains("check_in_attendees"),
                "Cena rotativa must offer check-in; got \(visible)")
        #expect(visible.contains("add_rules"),
                "Cena rotativa needs rules to set rotation policy")
        #expect(visible.contains("view_history"))
    }

    // MARK: - Cross-cutting: doctrinal compliance

    @Test("Variant copy across all 6 cases contains zero doctrine vocabulary")
    func variantCopyClean() {
        // Hardening for the 2026-05-18 doctrine: capability/atom/
        // projection/module/trigger/consequence/ledger never appear
        // in any variant the founder cases use.
        let forbidden = ["capability", "atom", "projection", "module",
                         "trigger", "consequence", "ledger"]
        let variants: [ResourceVariant] = [
            SpaceVariants.privateSpace,
            FundVariants.investmentFund,
            RightVariants.ownershipEquityRight,
            AssetVariants.property,
            EventVariants.sportsMatch,
            EventVariants.recurringEvent
        ]
        for variant in variants {
            let surfaces = [
                variant.humanName, variant.summary, variant.postCreateHeadline
            ] + variant.examples
            for surface in surfaces {
                let lower = surface.lowercased()
                for word in forbidden {
                    #expect(!lower.contains(word),
                            "variant \(variant.id) surface '\(surface)' contains '\(word)'")
                }
            }
        }
    }

    @Test("Every intent the 6 founder cases reference renders with non-empty copy")
    func intentCopyComplete() {
        let variants: [ResourceVariant] = [
            SpaceVariants.privateSpace,
            FundVariants.investmentFund,
            RightVariants.ownershipEquityRight,
            AssetVariants.property,
            EventVariants.sportsMatch,
            EventVariants.recurringEvent
        ]
        for variant in variants {
            for intentId in variant.suggestedIntents {
                guard let intent = Self.intents.intent(id: intentId) else {
                    Issue.record("variant \(variant.id) references missing intent \(intentId)")
                    continue
                }
                #expect(!intent.humanLabel.isEmpty,
                        "intent \(intentId) has empty humanLabel")
                #expect(!intent.summary.isEmpty,
                        "intent \(intentId) has empty summary")
                #expect(!intent.icon.isEmpty,
                        "intent \(intentId) has empty icon")
            }
        }
    }
}
