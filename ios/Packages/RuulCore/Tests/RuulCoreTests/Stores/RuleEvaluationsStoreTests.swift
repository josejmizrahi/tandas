import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("RuleEvaluationsStore (V2-G3.5)")
struct RuleEvaluationsStoreTests {

    private let groupId = UUID()

    private func evaluation(ruleId: UUID = UUID(), at: Date = Date()) -> GroupRuleEvaluation {
        GroupRuleEvaluation(
            id: UUID(), ruleId: ruleId, ruleTitle: "Title",
            ruleVersionId: UUID(), matched: true, depth: 0, createdAt: at
        )
    }

    private func makeStore(
        seed: [GroupRuleEvaluation] = [],
        pageSize: Int = 50
    ) async -> (RuleEvaluationsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupRuleEvaluationsStub(.success(seed))
        let repo = CanonicalRuleEvaluationsRepository(rpc: mock)
        return (RuleEvaluationsStore(repository: repo, pageSize: pageSize), mock)
    }

    @Test("refresh happy path lands on .loaded with the page")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [evaluation(), evaluation()])
        await store.refresh(groupId: groupId)
        #expect(store.evaluations.count == 2)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(where: {
            if case .groupRuleEvaluations(let g, _, _) = $0 { return g == groupId }
            return false
        }))
    }

    @Test("hasMore is true when page is full and false when underfilled")
    func hasMoreReflectsPageFill() async {
        let full = (0..<3).map { _ in evaluation() }
        let (store, _) = await makeStore(seed: full, pageSize: 3)
        await store.refresh(groupId: groupId)
        #expect(store.hasMore == true)

        let half = [evaluation()]
        let (store2, _) = await makeStore(seed: half, pageSize: 3)
        await store2.refresh(groupId: groupId)
        #expect(store2.hasMore == false)
    }

    @Test("ruleFilter clips visibleEvaluations to that rule")
    func ruleFilterClipsLocally() async {
        let r1 = UUID(); let r2 = UUID()
        let mixed = [evaluation(ruleId: r1), evaluation(ruleId: r2), evaluation(ruleId: r1)]
        let (store, _) = await makeStore(seed: mixed)
        await store.refresh(groupId: groupId)
        #expect(store.evaluations.count == 3)
        store.ruleFilter = r1
        #expect(store.visibleEvaluations.count == 2)
        store.ruleFilter = nil
        #expect(store.visibleEvaluations.count == 3)
    }

    @Test("refresh failure flips phase to .failed and exposes message")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupRuleEvaluationsStub(.failure(RuulError.backend(.unknown(message: "nope"))))
        let store = RuleEvaluationsStore(
            repository: CanonicalRuleEvaluationsRepository(rpc: mock)
        )
        await store.refresh(groupId: groupId)
        if case .failed(let message) = store.phase {
            #expect(message.isEmpty == false)
        } else {
            Issue.record("expected .failed phase, got \(store.phase)")
        }
        #expect(store.errorMessage != nil)
    }
}
