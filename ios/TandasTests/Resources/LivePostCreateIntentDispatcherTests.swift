import Testing
import Foundation
import RuulCore
@testable import RuulFeatures

@Suite("LivePostCreateIntentDispatcher")
struct LivePostCreateIntentDispatcherTests {

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

    private func makeActivator(seed: [ResourceCapability] = []) -> LazyCapabilityActivator {
        LazyCapabilityActivator(
            catalog: .v1,
            resolver: CapabilityResolver(modules: .v1Fallback),
            capabilityRepo: MockResourceCapabilityRepository(seed: seed)
        )
    }

    /// Captures the (intent, outcome) pair emitted to onActivated.
    /// @MainActor class so the callback (also @MainActor) can write
    /// synchronously — no Task hop, no scheduling race.
    @MainActor
    private final class Captor {
        var calls: [(intent: ResourceIntent, outcome: ActivationOutcome)] = []
        func record(_ intent: ResourceIntent, _ outcome: ActivationOutcome) {
            calls.append((intent, outcome))
        }
    }

    @Test("dispatch with empty requiredCapabilities short-circuits and emits empty outcome")
    @MainActor
    func emptyCapsShortCircuit() async throws {
        let captor = Captor()
        let dispatcher = LivePostCreateIntentDispatcher(
            activator: makeActivator(),
            onActivated: { intent, outcome in
                captor.record(intent, outcome)
            }
        )
        // view_history has empty requiredCapabilities.
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "view_history")!
        try await dispatcher.dispatch(
            intent,
            on: UUID(),
            resourceType: .event,
            in: makeGroup(activeModules: [])
        )
        #expect(captor.calls.count == 1)
        #expect(captor.calls[0].intent.id == "view_history")
        #expect(captor.calls[0].outcome.attached.isEmpty)
        #expect(captor.calls[0].outcome.alreadyAttached.isEmpty)
    }

    @Test("dispatch attaches caps via activator and emits attached set")
    @MainActor
    func attachesCaps() async throws {
        let captor = Captor()
        let dispatcher = LivePostCreateIntentDispatcher(
            activator: makeActivator(),
            onActivated: { intent, outcome in
                captor.record(intent, outcome)
            }
        )
        // invite_people needs rsvp; group has rsvp module.
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "invite_people")!
        try await dispatcher.dispatch(
            intent,
            on: UUID(),
            resourceType: .event,
            in: makeGroup(activeModules: ["rsvp"])
        )
        #expect(captor.calls.count == 1)
        #expect(captor.calls[0].outcome.attached.contains("rsvp"))
    }

    @Test("dispatch throws .capabilitiesUnavailable when caps can't activate")
    @MainActor
    func throwsWhenUnavailable() async {
        let captor = Captor()
        let dispatcher = LivePostCreateIntentDispatcher(
            activator: makeActivator(),
            onActivated: { intent, outcome in
                captor.record(intent, outcome)
            }
        )
        // invite_people needs rsvp; group does NOT have rsvp module.
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "invite_people")!
        do {
            try await dispatcher.dispatch(
                intent,
                on: UUID(),
                resourceType: .event,
                in: makeGroup(activeModules: [])
            )
            Issue.record("expected throw, got success")
        } catch let error as IntentDispatchError {
            if case .capabilitiesUnavailable(let ids) = error {
                #expect(ids.contains("rsvp"))
            } else {
                Issue.record("expected .capabilitiesUnavailable, got \(error)")
            }
        } catch {
            Issue.record("expected IntentDispatchError, got \(error)")
        }
        // onActivated must NOT fire when caps are unavailable.
        #expect(captor.calls.isEmpty)
    }

    @Test("already-attached caps satisfy without calling activator")
    @MainActor
    func alreadyAttachedSatisfies() async throws {
        let resourceId = UUID()
        // Pre-seed: rsvp already enabled on this resource (matching
        // what the silent-attach path at create-time would have done).
        let seed = [
            ResourceCapability(
                resourceId: resourceId,
                capabilityBlockId: "rsvp",
                config: .object([:]),
                enabled: true,
                enabledAt: .now,
                enabledBy: nil
            )
        ]
        let captor = Captor()
        let dispatcher = LivePostCreateIntentDispatcher(
            activator: makeActivator(seed: seed),
            onActivated: { intent, outcome in
                captor.record(intent, outcome)
            }
        )
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "invite_people")!
        try await dispatcher.dispatch(
            intent,
            on: resourceId,
            resourceType: .event,
            in: makeGroup(activeModules: ["rsvp"])
        )
        #expect(captor.calls.count == 1)
        #expect(captor.calls[0].outcome.alreadyAttached.contains("rsvp"))
        #expect(!captor.calls[0].outcome.attached.contains("rsvp"))
    }
}
