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

    /// V3 — `record_contribution(...)` para aportar dinero al pool del
    /// grupo. A diferencia de `recordOwnExpense`, esto NO genera
    /// obligations peer-to-peer; acredita directamente al balance del
    /// grupo. Cuando `resourceId != nil` el monto se attribuye al
    /// recurso específico (e.g. fondo común con nombre).
    public func recordContribution(
        groupId: UUID,
        fromMembershipId: UUID,
        amount: Decimal,
        unit: String = "MXN",
        resourceId: UUID? = nil,
        description: String? = nil,
        inKind: Bool = false,
        mandateId: UUID? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.recordContribution(
            RecordContributionParams(
                groupId: groupId,
                resourceId: resourceId,
                amount: amount,
                unit: unit,
                fromMembershipId: fromMembershipId,
                description: description,
                inKind: inKind,
                mandateId: mandateId,
                clientId: clientId
            )
        )
    }

    /// V3 — `group_pool_balance(p_group_id)` agregado del fondo común.
    public func poolBalance(groupId: UUID) async throws -> GroupPoolBalance {
        try await rpc.groupPoolBalance(groupId: groupId)
    }

    /// V3 — `record_pool_charge(...)` crea una obligation pool-side
    /// contra un miembro. Backend valida charge_kind in
    /// (quota/buy_in/fee) + permission `pool_charge.record`.
    public func recordPoolCharge(
        groupId: UUID,
        targetMembershipId: UUID,
        amount: Decimal,
        unit: String = "MXN",
        chargeKind: String,
        reason: String? = nil,
        mandateId: UUID? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.recordPoolCharge(
            RecordPoolChargeParams(
                groupId: groupId,
                targetMembershipId: targetMembershipId,
                amount: amount,
                unit: unit,
                chargeKind: chargeKind,
                reason: reason,
                mandateId: mandateId,
                clientId: clientId
            )
        )
    }

    /// V3 — `record_pool_charge_batch(...)`. Atomic: si una falla,
    /// rollback total. Returns count de obligations creadas.
    public func recordPoolChargeBatch(
        groupId: UUID,
        targetMembershipIds: [UUID],
        amount: Decimal,
        unit: String = "MXN",
        chargeKind: String,
        reason: String? = nil,
        mandateId: UUID? = nil,
        clientIdBase: String? = nil
    ) async throws -> Int {
        try await rpc.recordPoolChargeBatch(
            RecordPoolChargeBatchParams(
                groupId: groupId,
                targetMembershipIds: targetMembershipIds,
                amount: amount,
                unit: unit,
                chargeKind: chargeKind,
                reason: reason,
                mandateId: mandateId,
                clientIdBase: clientIdBase
            )
        )
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

    /// V3-SE-1 — Splitwise-style "Settle up" plan from the caller's
    /// perspective. Returns one item per peer counterparty with a
    /// non-zero netted balance. Items are ordered by `|netAmount|`
    /// descending so the UI shows the biggest knots first.
    public func settlementPlan(groupId: UUID, membershipId: UUID) async throws -> [SettlementPlanItem] {
        try await rpc.groupSettlementPlanForMember(groupId: groupId, membershipId: membershipId)
    }
}
