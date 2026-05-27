import Foundation
import Testing
@testable import RuulCore

@Suite("CanonicalMoneyRepository")
struct CanonicalMoneyRepositoryTests {

    private func draft(amount: Decimal = 300, split: ExpenseSplit = .even) -> ExpenseDraft {
        ExpenseDraft(
            groupId: UUID(),
            resourceId: nil,
            amount: amount,
            paidByMembershipId: UUID(),
            description: "x",
            split: split,
            inKind: false
        )
    }

    @Test("recordOwnExpense forwards the draft + clientId unchanged")
    func recordOwnExpense() async throws {
        let mock = MockRuulRPCClient()
        let returnedId = UUID()
        await mock.setRecordExpenseStub(.success(returnedId))
        let repo = CanonicalMoneyRepository(rpc: mock)

        let d = draft()
        let id = try await repo.recordOwnExpense(d, clientId: "submit-1")
        #expect(id == returnedId)

        let calls = await mock.recorded
        #expect(calls == [.recordExpense(draft: d, clientId: "submit-1")])
    }

    @Test("recordOwnExpense keeps the same clientId on retry (idempotency contract)")
    func recordOwnExpenseIdempotency() async throws {
        let mock = MockRuulRPCClient()
        // First call fails, second succeeds — same clientId both times.
        await mock.setRecordExpenseStub(.failure(.network(message: "timeout")))
        let repo = CanonicalMoneyRepository(rpc: mock)
        let d = draft()
        let clientId = "submit-7"

        await #expect(throws: RuulError.network(message: "timeout")) {
            _ = try await repo.recordOwnExpense(d, clientId: clientId)
        }

        await mock.setRecordExpenseStub(.success(UUID()))
        _ = try await repo.recordOwnExpense(d, clientId: clientId)

        let calls = await mock.recorded
        #expect(calls.count == 2)
        // Both recorded calls must reuse the same clientId.
        for call in calls {
            if case .recordExpense(_, let cid) = call {
                #expect(cid == clientId)
            } else {
                Issue.record("expected only recordExpense calls")
            }
        }
    }

    @Test("recordOwnSettlement returns settlement + transaction ids")
    func recordOwnSettlement() async throws {
        let mock = MockRuulRPCClient()
        let result = SettlementResult(settlementId: UUID(), transactionId: UUID())
        await mock.setRecordSettlementStub(.success(result))
        let repo = CanonicalMoneyRepository(rpc: mock)

        let draft = SettlementDraft(
            groupId: UUID(),
            paidByMembershipId: UUID(),
            target: .pool,
            amount: 100
        )
        let out = try await repo.recordOwnSettlement(draft, clientId: nil)
        #expect(out == result)
    }

    @Test("recordOwnSettlement surfaces .customSplitMismatch and stops calling")
    func recordOwnExpenseSplitMismatch() async throws {
        let mock = MockRuulRPCClient()
        await mock.setRecordExpenseStub(.failure(.backend(.customSplitMismatch(sum: 90, expected: 100))))
        let repo = CanonicalMoneyRepository(rpc: mock)

        await #expect(throws: RuulError.backend(.customSplitMismatch(sum: 90, expected: 100))) {
            _ = try await repo.recordOwnExpense(draft(), clientId: "x")
        }
    }

    @Test("obligationSummary returns the rows the RPC returned")
    func obligationSummary() async throws {
        let mock = MockRuulRPCClient()
        let row = ObligationSummary(
            id: UUID(),
            kind: "expense_share",
            amountOutstanding: 33,
            owedToKind: "member",
            owedToMembershipId: UUID(),
            owedToLabel: "Ana"
        )
        await mock.setMemberObligationSummaryStub(.success([row]))
        let repo = CanonicalMoneyRepository(rpc: mock)

        let result = try await repo.obligationSummary(groupId: UUID(), membershipId: UUID())
        #expect(result == [row])
    }

    @Test("balance returns the signed scalar")
    func balance() async throws {
        let mock = MockRuulRPCClient()
        await mock.setMemberBalanceStub(.success(Decimal(-150)))
        let repo = CanonicalMoneyRepository(rpc: mock)

        let value = try await repo.balance(groupId: UUID(), membershipId: UUID())
        #expect(value == -150)
    }
}
