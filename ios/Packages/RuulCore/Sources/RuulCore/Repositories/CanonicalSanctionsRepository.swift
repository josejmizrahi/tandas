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
}
