import Foundation

/// Foundation-scope repository for Primitiva 19 (Accounting) read
/// surface. Reads via `group_money_movements(...)`. Write paths
/// (record_expense, record_settlement_v2, pay_sanction, …) stay on
/// their own repositories; iOS never appends to the ledger directly.
public struct CanonicalMovementsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Newest-first page of money movements. `filter` is the set of
    /// canonical `transaction_type` strings to keep (nil = all).
    /// `beforeSeq` is the cursor for infinite scroll — pass the
    /// smallest `seq` from the previous page.
    public func movements(
        groupId: UUID,
        limit: Int = 50,
        filter: [String]? = nil,
        beforeSeq: Int64? = nil
    ) async throws -> [MoneyMovement] {
        try await rpc.groupMoneyMovements(
            groupId: groupId,
            limit: limit,
            filter: filter,
            beforeSeq: beforeSeq
        )
    }
}
