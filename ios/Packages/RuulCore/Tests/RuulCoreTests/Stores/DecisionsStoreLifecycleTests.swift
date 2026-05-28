import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("DecisionsStore lifecycle")
struct DecisionsStoreLifecycleTests {

    private var groupId: UUID { DecisionsStoreFixture.groupId }

    @Test("refresh loads open + history buckets")
    func refreshHappyPath() async {
        let (store, _) = await DecisionsStoreFixture.makeStore(
            open: [DecisionsStoreFixture.summary(), DecisionsStoreFixture.summary()],
            history: [DecisionsStoreFixture.summary(status: .passed)]
        )
        await store.refresh(groupId: groupId)
        #expect(store.open.count == 2)
        #expect(store.history.count == 1)
        #expect(store.phase == .loaded)
    }

    @Test("refresh failure surfaces message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setListDecisionsActiveStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        await mock.setListDecisionsHistoryStub(.success([]))
        let store = DecisionsStore(repository: CanonicalDecisionsRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }

    @Test("finalize calls finalize_vote and refreshes")
    func finalizeRefreshes() async {
        let did = UUID()
        let (store, mock) = await DecisionsStoreFixture.makeStore()
        let ok = await store.finalize(decisionId: did, groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .finalizeVote(let id) = call { return id == did }
            return false
        })
        // refresh is implicit; the active+history stubs return empty by default
        #expect(recorded.contains { call in
            if case .listDecisionsActive(let gid) = call { return gid == groupId }
            return false
        })
    }

    @Test("loadDetail caches the detail and flips phase")
    func loadDetailHappyPath() async {
        let mock = MockRuulRPCClient()
        let did = UUID()
        let stubbed = GroupDecisionDetail(
            id: did, groupId: groupId, title: "Pizza",
            method: .majority, status: .open
        )
        await mock.setDecisionDetailStub(.success(stubbed))
        let store = DecisionsStore(repository: CanonicalDecisionsRepository(rpc: mock))
        await store.loadDetail(decisionId: did)
        #expect(store.detail?.id == did)
        #expect(store.detailPhase == .loaded)
    }
}
