import Foundation
@testable import RuulCore

/// Shared fixture builders for the `DecisionsStore*` test suites.
/// Living in a single file keeps each `@Suite` small so Xcode's IDE
/// type-checker (which choked on a 549-line @Suite with many
/// enum-pattern closures) can keep up with live diagnostics.
@MainActor
enum DecisionsStoreFixture {
    static let groupId = UUID()

    static func summary(status: DecisionStatus = .open) -> GroupDecisionSummary {
        GroupDecisionSummary(
            id: UUID(),
            groupId: groupId,
            title: "Decisión #\(Int.random(in: 1...999))",
            decisionType: .proposal,
            method: .majority,
            status: status,
            optionCount: 0,
            tally: GroupDecisionTally(voteCount: 0)
        )
    }

    static func makeStore(
        open: [GroupDecisionSummary] = [],
        history: [GroupDecisionSummary] = []
    ) async -> (DecisionsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setListDecisionsActiveStub(.success(open))
        await mock.setListDecisionsHistoryStub(.success(history))
        let repo = CanonicalDecisionsRepository(rpc: mock)
        return (DecisionsStore(repository: repo), mock)
    }
}
