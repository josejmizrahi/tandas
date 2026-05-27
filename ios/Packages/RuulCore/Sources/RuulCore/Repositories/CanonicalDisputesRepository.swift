import Foundation

/// Foundation-scope repository for Primitiva 14 (Disputas). Reads via
/// `group_disputes_active(...)` and opens sanction disputes via
/// `dispute_sanction(...)`. open_dispute / mediate / resolve / escalate
/// surfaces land in a later slice (Plan §B6 full).
public struct CanonicalDisputesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeDisputes(groupId: UUID, limit: Int = 50) async throws -> [GroupDispute] {
        try await rpc.groupDisputesActive(groupId: groupId, limit: limit)
    }

    /// Opens a dispute against an existing sanction. Trims summary
    /// before sending; backend re-trims defensively.
    public func disputeSanction(sanctionId: UUID, summary: String) async throws -> UUID {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = DisputeSanctionInput(pSanctionId: sanctionId, pSummary: trimmed)
        return try await rpc.disputeSanction(input)
    }
}
