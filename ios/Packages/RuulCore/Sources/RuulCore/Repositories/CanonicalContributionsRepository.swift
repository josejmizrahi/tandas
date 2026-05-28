import Foundation

/// Foundation-scope repository for Primitiva 9 (Contribuciones).
/// Reads via `group_contributions_active(...)`; writes via
/// `log_contribution`. Verify path lives on the backend
/// (`contribution.verify` perm) and lands with a dedicated review
/// surface — Foundation does not expose it here.
public struct CanonicalContributionsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeContributions(
        groupId: UUID,
        membershipId: UUID? = nil,
        resourceId: UUID? = nil
    ) async throws -> [GroupContribution] {
        try await rpc.groupContributionsActive(
            groupId: groupId,
            membershipId: membershipId,
            resourceId: resourceId
        )
    }

    public func log(
        groupId: UUID,
        type: ContributionType,
        title: String?,
        description: String?,
        amount: Decimal? = nil,
        unit: String? = nil,
        sourceResourceId: UUID? = nil,
        occurredAt: Date? = nil
    ) async throws -> UUID {
        let trimTitle = title.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let trimDesc = description.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let trimUnit = unit.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let input = LogContributionParams(
            groupId: groupId,
            contributionType: type.rawValue,
            title: trimTitle,
            description: trimDesc,
            amount: amount,
            unit: trimUnit,
            sourceResourceId: sourceResourceId,
            occurredAt: occurredAt
        )
        return try await rpc.logContribution(input)
    }
}
