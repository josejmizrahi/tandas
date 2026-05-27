import Foundation

/// Foundation-scope repository for the canonical money loop — self-party
/// expense + self-party settlement + balance/obligation reads. The two
/// mutating methods carry `recordOwn*` names so callers can't reach a
/// third-party path from Foundation; mandates V2 add that surface later.
///
/// Coexists with the legacy `LedgerRepository` / `FundRepository`. iOS
/// never computes balances or obligation closures locally — those reads
/// always round-trip through the canonical RPCs.
public struct CanonicalMoneyRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// `record_expense(...)` for `paid_by = caller`. Foundation hardcodes
    /// `p_mandate_id = nil` (set inside `RecordExpenseParams.init(draft:)`)
    /// so the RPC's authority resolver classifies the row as `self_party`.
    ///
    /// `clientId` must be stable across retries — the caller (view model
    /// or store) mints it once per submit and keeps reusing it until the
    /// operation either succeeds or is cancelled. Passing `nil` means
    /// "no idempotency guard, treat every call as fresh".
    public func recordOwnExpense(_ draft: ExpenseDraft, clientId: String? = nil) async throws -> UUID {
        try await rpc.recordExpense(draft, clientId: clientId)
    }

    /// `record_settlement(...)` for `paid_by = caller`. Same idempotency
    /// contract as `recordOwnExpense`. Returns both the new settlement
    /// row and the ledger transaction id materialised by the close.
    public func recordOwnSettlement(_ draft: SettlementDraft, clientId: String? = nil) async throws -> SettlementResult {
        try await rpc.recordSettlement(draft, clientId: clientId)
    }

    /// `member_obligation_summary(p_group_id, p_membership_id)` — open
    /// obligations (debt rows) for the membership in this group, with
    /// human label for the counterparty.
    public func obligationSummary(groupId: UUID, membershipId: UUID) async throws -> [ObligationSummary] {
        try await rpc.memberObligationSummary(groupId: groupId, membershipId: membershipId)
    }

    /// `member_balance_in_group(p_group_id, p_membership_id)` — signed
    /// scalar (positive = group owes member, negative = member owes
    /// group). Display is the caller's responsibility.
    public func balance(groupId: UUID, membershipId: UUID) async throws -> Decimal {
        try await rpc.memberBalance(groupId: groupId, membershipId: membershipId)
    }
}
