import Foundation

/// Foundation-scope repository for Primitiva 9 (Contribuciones).
/// Reads via `group_contributions_active(...)`; writes via
/// `log_contribution` (self-claim) and `verify_contribution`
/// (third-party flip a `verified` / `rejected`).
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

    public func verify(
        contributionId: UUID,
        outcome: ContributionVerifyOutcome,
        note: String? = nil
    ) async throws {
        let trimNote = note.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let input = VerifyContributionParams(
            contributionId: contributionId,
            outcome: outcome.rawValue,
            note: trimNote
        )
        try await rpc.verifyContribution(input)
    }
}

/// Wire value the backend accepts on `verify_contribution.p_outcome`.
public enum ContributionVerifyOutcome: String, Sendable, Equatable {
    case verified
    case rejected
}
