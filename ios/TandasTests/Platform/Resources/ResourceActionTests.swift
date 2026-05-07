import XCTest
@testable import Tandas

final class ResourceActionTests: XCTestCase {

    // MARK: - Fixture

    private func makeAction(
        id: String = "test-action",
        subtitle: String? = nil,
        isDestructive: Bool = false,
        onTap: @escaping @Sendable () async -> Void = {}
    ) -> ResourceAction {
        ResourceAction(
            id: id,
            icon: "xmark.circle",
            title: "Test action",
            subtitle: subtitle,
            isDestructive: isDestructive,
            governanceAction: .closeEvents,
            onTap: onTap
        )
    }

    // MARK: - Tests

    func testInitWithDefaults() {
        // Use the call-site that omits subtitle and isDestructive to
        // exercise the default-arg path on the public init.
        let action = ResourceAction(
            id: "id1",
            icon: "xmark.circle",
            title: "Title",
            governanceAction: .closeEvents,
            onTap: {}
        )

        XCTAssertEqual(action.id, "id1")
        XCTAssertEqual(action.icon, "xmark.circle")
        XCTAssertEqual(action.title, "Title")
        XCTAssertNil(action.subtitle)
        XCTAssertFalse(action.isDestructive)
        XCTAssertEqual(action.governanceAction, .closeEvents)
    }

    func testIdIsStableAcrossClosures() {
        // Same id, different closures — id is the stable diff key for
        // SwiftUI ForEach. Closures cannot be compared structurally.
        let a1 = makeAction(id: "stable", onTap: {})
        let a2 = makeAction(id: "stable", onTap: { /* different body */ })
        XCTAssertEqual(a1.id, a2.id)
    }

    func testOnTapExecutesClosure() async {
        actor Counter {
            var value: Int = 0
            func increment() { value += 1 }
            func current() -> Int { value }
        }
        let counter = Counter()
        let action = makeAction(id: "tap") {
            await counter.increment()
        }

        await action.onTap()

        let observed = await counter.current()
        XCTAssertEqual(observed, 1)
    }
}
