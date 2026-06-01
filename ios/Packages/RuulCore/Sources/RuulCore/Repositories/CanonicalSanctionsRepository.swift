import Foundation

/// Foundation-scope repository for Primitiva 11 (Sanciones). Reads via
/// `group_sanctions_active(...)` and issues via `issue_sanction(...)`.
/// Update/dispute paths exist at the RPC layer but are deferred to the
/// Disputes slice (Plan §B6) — Foundation only exposes issuance.
public struct CanonicalSanctionsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeSanctions(groupId: UUID, limit: Int = 50) async throws -> [GroupSanction] {
        try await rpc.groupSanctionsActive(groupId: groupId, limit: limit)
    }

    /// Trims `reason` before sending; backend re-trims defensively.
    /// For monetary kinds, callers MUST pass amount + unit; backend
    /// raises `monetary sanction requires positive amount + unit`
    /// otherwise (mapped to `.monetarySanctionRequiresAmountUnit`).
    public func issueSanction(
        groupId: UUID,
        targetMembershipId: UUID,
        kind: SanctionKind,
        reason: String,
        amount: Decimal? = nil,
        unit: String? = nil,
        endsAt: Date? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let input = IssueSanctionInput(
            pGroupId: groupId,
            pTargetMembershipId: targetMembershipId,
            pSanctionKind: kind.rawValue,
            pReason: trimmedReason,
            pAmount: amount,
            pUnit: trimmedUnit,
            pEndsAt: endsAt,
            pClientId: clientId
        )
        return try await rpc.issueSanction(input)
    }

    /// D24P10B — governance-aware issue. Resolver decide direct (admin
    /// para sanctions menores) vs decisión cuando es monetary > threshold.
    /// Hoy el threshold lo evalúa el backend resolver (lee
    /// `groups.governance.action_thresholds.money_sanction_issue` per memory).
    public func issueSanctionViaGovernance(
        groupId: UUID,
        targetMembershipId: UUID,
        kind: SanctionKind,
        reason: String,
        amount: Decimal? = nil,
        unit: String? = nil,
        endsAt: Date? = nil,
        clientId: String? = nil
    ) async throws -> ActionOutcome {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var payload: [String: RPCJSONValue] = [
            "target_membership_id": .string(targetMembershipId.uuidString),
            "sanction_kind":        .string(kind.rawValue),
            "reason":               .string(trimmedReason)
        ]
        if let amount { payload["amount"] = .number(amount) }
        if let trimmedUnit { payload["unit"] = .string(trimmedUnit) }
        if let endsAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            payload["ends_at"] = .string(formatter.string(from: endsAt))
        }
        if let clientId { payload["client_id"] = .string(clientId) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "money.sanction.issue",
                targetKind: "membership",
                targetId:   targetMembershipId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            _ = try await issueSanction(
                groupId: groupId, targetMembershipId: targetMembershipId,
                kind: kind, reason: trimmedReason, amount: amount,
                unit: trimmedUnit, endsAt: endsAt, clientId: clientId)
        }
        return outcome
    }

    /// V2-G4.1 — payment progress for the PaySanctionSheet pre-fill +
    /// the SanctionDetailView progress bar.
    public func paymentStatus(sanctionId: UUID) async throws -> SanctionPaymentStatus {
        try await rpc.groupSanctionPaymentStatus(sanctionId: sanctionId)
    }

    /// V2-G4.2 — active payment plan for a sanction, if any.
    public func paymentPlan(sanctionId: UUID) async throws -> SanctionPaymentPlan {
        try await rpc.groupSanctionPaymentPlanActive(sanctionId: sanctionId)
    }

    /// V2-G4.2 — target proposes a plan. Auto-active al backend.
    public func proposePaymentPlan(
        sanctionId: UUID,
        installments: Int,
        firstDueAt: Date,
        intervalDays: Int = 30,
        notes: String? = nil
    ) async throws -> UUID {
        try await rpc.proposeSanctionPaymentPlan(
            ProposeSanctionPaymentPlanParams(
                sanctionId: sanctionId,
                installments: installments,
                firstDueAt: firstDueAt,
                intervalDays: intervalDays,
                notes: notes
            )
        )
    }

    /// V2-G4.2 — cancel an active plan. Target or admin.
    public func cancelPaymentPlan(planId: UUID, reason: String? = nil) async throws {
        try await rpc.cancelSanctionPaymentPlan(
            CancelSanctionPaymentPlanParams(planId: planId, reason: reason)
        )
    }

    /// V3 PARTE 5a — self-party sugar `pay_sanction`. Para pagar
    /// on-behalf usar `moneyRepository.recordOwnSettlement` con mandato.
    /// Backend resuelve target_membership, fija paid_to_kind='pool', y
    /// rechaza over-pay.
    public func paySanction(
        sanctionId: UUID,
        amount: Decimal,
        unit: String? = nil,
        clientId: String? = nil
    ) async throws -> SettlementResult {
        try await rpc.paySanction(
            PaySanctionParams(
                sanctionId: sanctionId,
                amount: amount,
                unit: unit,
                clientId: clientId
            )
        )
    }
}
