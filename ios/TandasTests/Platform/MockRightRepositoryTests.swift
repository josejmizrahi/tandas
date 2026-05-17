import Testing
import Foundation
import RuulCore
@testable import Tandas

/// Round-trip tests for `MockRightRepository`. Pin down the protocol's
/// recorded-call shape so any future change to the contract surfaces in
/// the test suite first instead of as a silent UI no-op (the audit
/// flagged this kind of gap).
///
/// MockRightRepository is an `actor`, so property accesses from the
/// test body need `await`. The recorded-call arrays are read once into
/// a local snapshot to keep each #expect free of repeated awaits.
@Suite("MockRightRepository")
struct MockRightRepositoryTests {
    @Test("transfer records (rightId, memberId, reason)")
    func transferRecorded() async throws {
        let repo = MockRightRepository()
        let rid = UUID()
        let mid = UUID()
        try await repo.transfer(rid, to: mid, reason: "for testing")

        let recorded = await repo.transfers
        #expect(recorded.count == 1)
        #expect(recorded[0].0 == rid)
        #expect(recorded[0].1 == mid)
        #expect(recorded[0].2 == "for testing")
    }

    @Test("delegate records member + until + reason")
    func delegateRecorded() async throws {
        let repo = MockRightRepository()
        let rid = UUID()
        let mid = UUID()
        let until = Date.now.addingTimeInterval(86_400)
        try await repo.delegate(rid, to: mid, until: until, reason: nil)

        let recorded = await repo.delegations
        #expect(recorded.count == 1)
        #expect(recorded[0].0 == rid)
        #expect(recorded[0].1 == mid)
        #expect(recorded[0].2 == until)
        #expect(recorded[0].3 == nil)
    }

    @Test("revoke + suspend + restore record their args")
    func lifecycleRecorded() async throws {
        let repo = MockRightRepository()
        let rid = UUID()
        try await repo.revoke(rid, reason: "fines")
        try await repo.suspend(rid, until: nil, reason: nil)
        try await repo.restore(rid, reason: "appeal upheld")

        let revokes = await repo.revokes
        #expect(revokes.count == 1)
        #expect(revokes[0].0 == rid)
        #expect(revokes[0].1 == "fines")

        let suspensions = await repo.suspensions
        #expect(suspensions.count == 1)
        #expect(suspensions[0].1 == nil)

        let restorations = await repo.restorations
        #expect(restorations.count == 1)
        #expect(restorations[0].1 == "appeal upheld")
    }

    @Test("exercise records context jsonb")
    func exerciseRecorded() async throws {
        let repo = MockRightRepository()
        let rid = UUID()
        try await repo.exercise(rid, context: .object(["note": .string("checked in")]))

        let recorded = await repo.exercises
        #expect(recorded.count == 1)
        #expect(recorded[0].1["note"]?.stringValue == "checked in")
    }

    @Test("updateMetadata records the diff patch")
    func updateMetadataRecorded() async throws {
        let repo = MockRightRepository()
        let rid = UUID()
        let patch: JSONConfig = .object([
            "transferable": .bool(true),
            "priority":     .int(5),
        ])
        try await repo.updateMetadata(rid, patch: patch)

        let recorded = await repo.metadataUpdates
        #expect(recorded.count == 1)
        #expect(recorded[0].1["transferable"]?.boolValue == true)
        #expect(recorded[0].1["priority"]?.intValue == 5)
    }

    // (Intentional) No `nextError` test: `nextError` is actor-isolated
    // and no other mock in the codebase exposes a setter from outside.
    // Live-server error mapping is covered separately by
    // `LiveRightRepository.mapError`.
}
