import Testing
import Foundation
import RuulCore

@Suite("IntentVisibilityResolver")
struct IntentVisibilityResolverTests {
    private let resolver = IntentVisibilityResolver(
        catalog: .v1,
        resolver: CapabilityResolver(modules: .v1Fallback)
    )
    private let intents = DefaultResourceIntentRegistry.v1

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

    private func ctx(
        type: ResourceType,
        modules: [String],
        attached: Set<String> = [],
        perms: Set<Permission> = []
    ) -> IntentVisibilityContext {
        IntentVisibilityContext(
            resourceType: type,
            group: makeGroup(activeModules: modules),
            attachedCapabilities: attached,
            viewerPermissions: perms
        )
    }

    // MARK: - Type gate

    @Test("intent declared for .fund stays hidden on .event resource")
    func typeGate() {
        // record_contribution declares [.fund, .event]; record_expense
        // declares [.fund, .event, .asset, .space]. Pick something
        // narrower: invite_people declares only [.event].
        let invite = intents.intent(id: "invite_people")!
        let onFund = ctx(type: .fund, modules: ["rsvp"], attached: ["rsvp"])
        #expect(resolver.isVisible(invite, in: onFund) == false)
        let onEvent = ctx(type: .event, modules: ["rsvp"], attached: ["rsvp"])
        #expect(resolver.isVisible(invite, in: onEvent) == true)
    }

    // MARK: - Permission gate

    @Test("intent requiring modifyGovernance stays hidden without the permission")
    func permissionGate() {
        // change_control declares permissionsRequired: [.modifyGovernance].
        let change = intents.intent(id: "change_control")!
        let noPerm = ctx(type: .fund, modules: ["basic_fines"], perms: [])
        #expect(resolver.isVisible(change, in: noPerm) == false)
        let withPerm = ctx(type: .fund, modules: ["basic_fines"],
                           perms: [.modifyGovernance])
        #expect(resolver.isVisible(change, in: withPerm) == true)
    }

    // MARK: - Capability gate

    @Test("already-attached caps satisfy the gate without resolver lookup")
    func alreadyAttachedShortCircuit() {
        // track_money needs ledger + money. Group has neither module
        // active, but they're listed as attached on the resource → ok.
        let track = intents.intent(id: "track_money")!
        let withCapsAttached = ctx(
            type: .fund,
            modules: [],
            attached: ["ledger", "money"]
        )
        #expect(resolver.isVisible(track, in: withCapsAttached) == true)
    }

    @Test("missing caps with no active module → hidden")
    func unavailableCapsHidden() {
        // record_contribution needs ledger + money. With NO basic_fines
        // module and no attached caps, both are unavailable → hidden.
        let contribute = intents.intent(id: "record_contribution")!
        let noCaps = ctx(type: .fund, modules: [], attached: [])
        #expect(resolver.isVisible(contribute, in: noCaps) == false)
    }

    @Test("incomplete capability blocks (booking, access) stay hidden")
    func incompleteCapsHidden() {
        // allow_reservations needs `booking` which is .incomplete in v1.
        // Even with slot_assignment module active, the .incomplete gate
        // hides the intent. Doctrine: no toggles decorativos.
        let reserve = intents.intent(id: "allow_reservations")!
        let onSlot = ctx(type: .slot, modules: ["slot_assignment"], attached: [])
        #expect(resolver.isVisible(reserve, in: onSlot) == false)
    }

    // MARK: - Bulk filter

    @Test("visible() preserves input order while filtering")
    func visiblePreservesOrder() {
        let trio = [
            intents.intent(id: "view_history")!,            // no caps, all types → ok
            intents.intent(id: "allow_reservations")!,      // needs incomplete booking → drop
            intents.intent(id: "link_resource")!            // no caps, all types → ok
        ]
        let c = ctx(type: .space, modules: ["slot_assignment"])
        let visible = resolver.visible(trio, in: c)
        #expect(visible.map(\.id) == ["view_history", "link_resource"])
    }
}
