import Foundation

/// Foundation-scope repository for Primitiva 25 (Disolución). Reads
/// the active dissolution row via `group_dissolution_active(...)`;
/// writes via `propose_dissolution(...)` and `finalize_dissolution(...)`.
/// `approve_dissolution` is backend-only — it runs automatically when
/// the linked supermajority vote passes.
///
/// Foundation V1 collects only `reason`; `plan` / `asset_disposition`
/// / `obligations_plan` jsonb defaults are kept empty server-side
/// until a richer wizard lands.
public struct CanonicalDissolutionRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func current(groupId: UUID) async throws -> GroupDissolution? {
        try await rpc.groupDissolutionActive(groupId: groupId)
    }

    public func propose(groupId: UUID, reason: String) async throws -> UUID {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await rpc.proposeDissolution(
            ProposeDissolutionInput(groupId: groupId, reason: trimmed)
        )
    }

    public func finalize(dissolutionId: UUID) async throws {
        try await rpc.finalizeDissolution(
            FinalizeDissolutionInput(dissolutionId: dissolutionId)
        )
    }
}
