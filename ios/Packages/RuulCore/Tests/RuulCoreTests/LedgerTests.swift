import Testing
import Foundation
@testable import RuulCore

/// P1.9 — browser de ledger: decoding de `money_transactions`, lectura y void
/// en el mock, y el gateado de `canVoid` del store.
@Suite("P1.9 — Ledger / void_transaction")
@MainActor
struct LedgerTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.ruul.decode(T.self, from: Data(json.utf8))
    }

    private let collective = AppContext(
        id: UUID(), kind: .collective, subtype: "friend_group", displayName: "Grupo"
    )

    /// Mismo patrón canónico que MockClientTests: construir + seed una sola vez
    /// (demo() siembra en un Task detached — usar el constructor evita la carrera).
    private func makeDemoClient() async -> MockRuulRPCClient {
        let jose = CurrentActor(
            actor: ActorRecord(
                id: MockRuulRPCClient.DemoIds.jose,
                actorKind: .person,
                actorSubtype: "person",
                displayName: "José"
            )
        )
        let mock = MockRuulRPCClient(me: jose)
        await mock.seedDemoWorld()
        return mock
    }

    // MARK: - Decoding

    @Test("decodifica una fila de money_transactions")
    func decodesTransaction() throws {
        let json = """
        {
          "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "context_actor_id": "00000000-0000-0000-0000-0000000000c1",
          "from_actor_id": "00000000-0000-0000-0000-00000000000b",
          "to_actor_id": null,
          "transaction_type": "expense",
          "amount": 1300,
          "currency": "MXN",
          "status": "posted",
          "occurred_at": "2026-06-06T18:15:30+00:00",
          "metadata": {"description": "Cena"},
          "created_by_actor_id": "00000000-0000-0000-0000-00000000000b",
          "created_at": "2026-06-06T18:15:30+00:00"
        }
        """
        let txn = try decode(MoneyTransaction.self, json)
        #expect(txn.transactionType == "expense")
        #expect(txn.typeLabel == "Gasto")
        #expect(txn.amount == 1300)
        #expect(txn.isPosted)
        #expect(!txn.isVoided)
        #expect(txn.note == "Cena")
        #expect(txn.toActorId == nil)
    }

    @Test("decodifica el resultado de void_transaction")
    func decodesVoidResult() throws {
        let json = """
        {
          "transaction_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "status": "voided",
          "cancelled_obligations": ["00000000-0000-0000-0000-00000000000b"],
          "reversed_ledger_entries": 2
        }
        """
        let result = try decode(TransactionVoided.self, json)
        #expect(result.status == "voided")
        #expect(result.cancelledObligations.count == 1)
        #expect(result.reversedLedgerEntries == 2)
        #expect(!result.idempotentReplay)
    }

    // MARK: - Mock

    @Test("el mock lista las transacciones sembradas de Cena Semanal")
    func mockLists() async throws {
        let client = await makeDemoClient()
        let txns = try await client.listContextTransactions(contextId: MockRuulRPCClient.DemoIds.cenaSemanal)
        #expect(txns.count >= 3)
        #expect(txns.contains { $0.transactionType == "game_result" })
        #expect(txns.contains { $0.isVoided })
        // Orden descendente por occurred_at.
        let dates = txns.compactMap(\.occurredAt)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("void_transaction en el mock anula y es idempotente")
    func mockVoid() async throws {
        let client = await makeDemoClient()
        let txns = try await client.listContextTransactions(contextId: MockRuulRPCClient.DemoIds.cenaSemanal)
        let posted = try #require(txns.first { $0.isPosted && !$0.isSettlement })

        let result = try await client.voidTransaction(transactionId: posted.id, reason: "Duplicado")
        #expect(result.status == "voided")
        #expect(!result.idempotentReplay)

        // Replay → idempotente.
        let replay = try await client.voidTransaction(transactionId: posted.id, reason: nil)
        #expect(replay.idempotentReplay)

        // El estado quedó persistido.
        let after = try await client.listContextTransactions(contextId: MockRuulRPCClient.DemoIds.cenaSemanal)
        #expect(after.first { $0.id == posted.id }?.isVoided == true)
        #expect(after.first { $0.id == posted.id }?.voidReason == "Duplicado")
    }

    // MARK: - canVoid gating

    @Test("canVoid: creador o money.settle; nunca settlement ni voided")
    func canVoidGating() async {
        let me = UUID()
        let other = UUID()
        // RPC dummy — canVoid es puro, nunca lo toca.
        let rpc = await makeDemoClient()

        func store(_ txns: [MoneyTransaction], perms: [String]) -> LedgerStore {
            LedgerStore(rpc: rpc, previewTransactions: txns, permissions: perms, myActorId: me)
        }
        func txn(type: String = "expense", status: String = "posted", creator: UUID) -> MoneyTransaction {
            MoneyTransaction(id: UUID(), contextActorId: collective.id, transactionType: type,
                             amount: 100, currency: "MXN", status: status, createdByActorId: creator)
        }

        // Con money.settle puede anular una posted ajena.
        let settleStore = store([], perms: ["money.settle"])
        #expect(settleStore.canVoid(txn(creator: other), in: collective))

        // Sin permiso, pero soy el creador → puedo.
        let plainStore = store([], perms: [])
        #expect(plainStore.canVoid(txn(creator: me), in: collective))
        // Sin permiso y no soy creador → no.
        #expect(!plainStore.canVoid(txn(creator: other), in: collective))
        // Settlement nunca (ni con money.settle).
        #expect(!settleStore.canVoid(txn(type: "settlement", creator: other), in: collective))
        // Ya anulada → no.
        #expect(!settleStore.canVoid(txn(status: "voided", creator: other), in: collective))
    }
}
