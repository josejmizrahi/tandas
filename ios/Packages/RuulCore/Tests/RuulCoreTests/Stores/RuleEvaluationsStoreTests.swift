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

    // V2-G8.1 — refreshSummary populates the home-banner summary,
    // count=0 means banner stays invisible, errors are silent.

    @Test("refreshSummary populates summary with non-zero count")
    func summaryHappyPath() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupRuleEvaluationSummaryStub(.success(
            GroupRuleEvaluationSummary(
                evaluationsCount: 3,
                lastEvaluatedAt: Date(),
                hasFailures: false,
                windowHours: 24
            )
        ))
        let store = RuleEvaluationsStore(
            repository: CanonicalRuleEvaluationsRepository(rpc: mock)
        )
        await store.refreshSummary(groupId: groupId)
        #expect(store.summary?.evaluationsCount == 3)
        #expect(store.summary?.hasFailures == false)
        #expect(store.summary?.windowHours == 24)
        let recorded = await mock.recorded
        #expect(recorded.contains(where: {
            if case .groupRuleEvaluationSummary(let g, let w) = $0 {
                return g == groupId && w == 24
            }
            return false
        }))
    }

    @Test("refreshSummary tolerates zero count (banner stays hidden)")
    func summaryZeroCount() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupRuleEvaluationSummaryStub(.success(
            GroupRuleEvaluationSummary(evaluationsCount: 0)
        ))
        let store = RuleEvaluationsStore(
            repository: CanonicalRuleEvaluationsRepository(rpc: mock)
        )
        await store.refreshSummary(groupId: groupId)
        #expect(store.summary?.evaluationsCount == 0)
    }

    @Test("refreshSummary swallows failure (banner is non-critical chrome)")
    func summaryFailureSilent() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupRuleEvaluationSummaryStub(.failure(
            RuulError.backend(.unknown(message: "boom"))
        ))
        let store = RuleEvaluationsStore(
            repository: CanonicalRuleEvaluationsRepository(rpc: mock)
        )
        await store.refreshSummary(groupId: groupId)
        // Nothing thrown, summary stays nil, phase untouched.
        #expect(store.summary == nil)
        #expect(store.errorMessage == nil)
    }
}
