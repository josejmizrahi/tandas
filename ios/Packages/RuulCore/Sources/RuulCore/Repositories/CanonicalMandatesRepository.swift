import Foundation

/// Foundation-scope repository for Primitiva 23 (Mandatos). Reads via
/// `group_mandates_active(...)`; writes via `grant_mandate` and
/// `revoke_mandate`. Scope jsonb + source_decision_id are deferred to
/// later slices (Foundation grants `{}` scope and no linked decision).
public struct CanonicalMandatesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeMandates(groupId: UUID) async throws -> [GroupMandate] {
        try await rpc.groupMandatesActive(groupId: groupId)
    }

    public func grant(
        groupId: UUID,
        representativeMembershipId: UUID,
        type: MandateType,
        principalType: MandatePrincipalType = .group,
        principalId: UUID? = nil,
        endsAt: Date? = nil
    ) async throws -> UUID {
        let input = GrantMandateParams(
            groupId: groupId,
            representativeMembershipId: representativeMembershipId,
            mandateType: type.rawValue,
            principalType: principalType.rawValue,
            principalId: principalType == .group ? nil : principalId,
            endsAt: endsAt
        )
        return try await rpc.grantMandate(input)
    }

    public func revoke(mandateId: UUID, reason: String? = nil) async throws {
        let trimmed = reason.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        try await rpc.revokeMandate(RevokeMandateParams(mandateId: mandateId, reason: trimmed))
    }
}
