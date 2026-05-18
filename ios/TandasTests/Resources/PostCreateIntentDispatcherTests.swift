import Testing
import Foundation
import RuulCore

@Suite("PostCreateIntentDispatcher")
struct PostCreateIntentDispatcherTests {
    /// Captures the last dispatched intent for assertion. Sendable
    /// via actor since the dispatcher protocol is async.
    private actor CapturingDispatcher: PostCreateIntentDispatcher {
        private(set) var calls: [(intent: ResourceIntent, resourceId: UUID)] = []
        private(set) var shouldThrow = false

        func setShouldThrow(_ value: Bool) { shouldThrow = value }
        func dispatch(
            _ intent: ResourceIntent,
            on resourceId: UUID,
            resourceType: ResourceType,
            in group: Group
        ) async throws {
            calls.append((intent, resourceId))
            if shouldThrow {
                throw NSError(domain: "test", code: 1)
            }
        }
    }

    private func makeGroup() -> Group {
        Group(
            id: UUID(),
            name: "T",
            inviteCode: "t",
            activeModules: ["rsvp"],
            createdBy: UUID(),
            createdAt: .now
        )
    }

    @Test("NoOp dispatcher accepts any intent without throwing")
    func noOpNeverThrows() async throws {
        let noop = NoOpPostCreateIntentDispatcher()
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "view_history")!
        try await noop.dispatch(
            intent,
            on: UUID(),
            resourceType: .event,
            in: makeGroup()
        )
        // No assertion beyond "did not throw" — NoOp is defined by
        // its absence of behavior.
    }

    @Test("Capturing dispatcher records the call payload")
    func capturingRecordsCalls() async throws {
        let dispatcher = CapturingDispatcher()
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "invite_people")!
        let resourceId = UUID()
        try await dispatcher.dispatch(
            intent,
            on: resourceId,
            resourceType: .event,
            in: makeGroup()
        )
        let calls = await dispatcher.calls
        #expect(calls.count == 1)
        #expect(calls[0].intent.id == "invite_people")
        #expect(calls[0].resourceId == resourceId)
    }

    @Test("Dispatcher throws are propagated to the caller")
    func throwsPropagate() async {
        let dispatcher = CapturingDispatcher()
        await dispatcher.setShouldThrow(true)
        let intent = DefaultResourceIntentRegistry.v1.intent(id: "view_history")!
        do {
            try await dispatcher.dispatch(
                intent,
                on: UUID(),
                resourceType: .event,
                in: makeGroup()
            )
            Issue.record("expected throw, got success")
        } catch {
            #expect((error as NSError).domain == "test")
        }
    }
}
