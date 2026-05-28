import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("MoneyMovementsStore")
struct MoneyMovementsStoreTests {

    private let groupId = UUID()

    private func movement(_ type: MoneyMovementType, seq: Int64 = 1) -> MoneyMovement {
        MoneyMovement(
            id: UUID(),
            seq: seq,
            groupId: groupId,
            type: type,
            amount: Decimal(100),
            unit: "MXN"
        )
    }

    private func makeStore(seed: [MoneyMovement] = []) async -> (MoneyMovementsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupMoneyMovementsStub(.success(seed))
        let repo = CanonicalMovementsRepository(rpc: mock)
        return (MoneyMovementsStore(repository: repo), mock)
    }

    @Test("refresh loads movements and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [
            movement(.expense, seq: 10),
            movement(.settlementPayment, seq: 9)
        ])
        await store.refresh(groupId: groupId)
        #expect(store.movements.count == 2)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .groupMoneyMovements(let gid, _, let filter, let cursor) = call {
                return gid == groupId && filter == nil && cursor == nil
            }
            return false
        })
    }

    @Test("setFilter sends sorted wire filter and re-fetches")
    func setFilterReFetches() async {
        let (store, mock) = await makeStore(seed: [])
        await store.setFilter([.expense, .settlementPayment], groupId: groupId)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .groupMoneyMovements(_, _, let filter, _) = call {
                return filter == ["expense", "settlement_payment"]
            }
            return false
        })
    }

    @Test("reachedEnd flips true when fewer rows than pageSize come back")
    func reachedEndAfterShortPage() async {
        let (store, _) = await makeStore(seed: [movement(.expense)])
        await store.refresh(groupId: groupId)
        #expect(store.reachedEnd)
    }

    @Test("loadMore is no-op when reachedEnd is true")
    func loadMoreNoopAtEnd() async {
        let (store, mock) = await makeStore(seed: [movement(.expense, seq: 1)])
        await store.refresh(groupId: groupId)
        #expect(store.reachedEnd)
        await store.loadMore(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupMoneyMovements = $0 { return true } else { return false } }
        #expect(calls.count == 1) // only the original refresh
    }

    @Test("clear resets state to idle")
    func clearResetsState() async {
        let (store, _) = await makeStore(seed: [movement(.expense)])
        await store.refresh(groupId: groupId)
        store.clear()
        #expect(store.movements.isEmpty)
        #expect(store.phase == .idle)
        #expect(store.reachedEnd == false)
    }

    @Test("refresh failure surfaces user-facing message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupMoneyMovementsStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = MoneyMovementsStore(repository: CanonicalMovementsRepository(rpc: mock))

        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }
}
