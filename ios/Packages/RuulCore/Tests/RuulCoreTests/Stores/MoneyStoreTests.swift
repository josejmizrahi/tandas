import Foundation
import Testing
@testable import RuulCore

@Suite("MoneyStore")
struct MoneyStoreTests {

    @Test("refresh loads balance + obligations concurrently → .loaded")
    @MainActor
    func refreshHappy() async throws {
        let mock = MockRuulRPCClient()
        await mock.setMemberBalanceStub(.success(Decimal(-200)))
        let row = ObligationSummary(
            id: UUID(),
            kind: "expense_share",
            amountOutstanding: 50,
            owedToKind: "member",
            owedToLabel: "Ana"
        )
        await mock.setMemberObligationSummaryStub(.success([row]))
        let store = MoneyStore(repository: CanonicalMoneyRepository(rpc: mock))

        await store.refresh(groupId: UUID(), membershipId: UUID())
        #expect(store.balance == -200)
        #expect(store.obligations == [row])
        #expect(store.phase == .loaded)
    }

    @Test("refresh failure on either read flips the whole store to .failed")
    @MainActor
    func refreshFailureBalance() async throws {
        let mock = MockRuulRPCClient()
        await mock.setMemberBalanceStub(.failure(.backend(.callerNotActiveMember(groupId: nil))))
        await mock.setMemberObligationSummaryStub(.success([]))
        let store = MoneyStore(repository: CanonicalMoneyRepository(rpc: mock))

        await store.refresh(groupId: UUID(), membershipId: UUID())
        #expect(store.phase.failureMessage != nil)
    }

    @Test("refresh failure on obligation summary also flips to .failed")
    @MainActor
    func refreshFailureObligations() async throws {
        let mock = MockRuulRPCClient()
        await mock.setMemberBalanceStub(.success(0))
        await mock.setMemberObligationSummaryStub(.failure(.network(message: "off")))
        let store = MoneyStore(repository: CanonicalMoneyRepository(rpc: mock))

        await store.refresh(groupId: UUID(), membershipId: UUID())
        #expect(store.phase.failureMessage != nil)
    }

    @Test("clear resets state back to idle")
    @MainActor
    func clear() async throws {
        let mock = MockRuulRPCClient()
        await mock.setMemberBalanceStub(.success(100))
        let store = MoneyStore(repository: CanonicalMoneyRepository(rpc: mock))
        await store.refresh(groupId: UUID(), membershipId: UUID())
        #expect(store.balance == 100)

        store.clear()
        #expect(store.balance == nil)
        #expect(store.obligations.isEmpty)
        #expect(store.phase == .idle)
    }
}
