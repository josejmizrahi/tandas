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

    /// D.22 — governance-aware grant. Mandates delegate authority and
    /// the founder CAN override, but doctrine prefers the decision
    /// path; this opens a decision unless the resolver downgrades.
    public func grantViaGovernance(
        groupId: UUID,
        representativeMembershipId: UUID,
        type: MandateType,
        principalType: MandatePrincipalType = .group,
        principalId: UUID? = nil,
        endsAt: Date? = nil
    ) async throws -> ActionOutcome {
        var payload: [String: RPCJSONValue] = [
            "representative_membership_id": .string(representativeMembershipId.uuidString),
            "mandate_type":   .string(type.rawValue),
            "principal_type": .string(principalType.rawValue)
        ]
        if principalType != .group, let principalId {
            payload["principal_id"] = .string(principalId.uuidString)
        }
        if let endsAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            payload["ends_at"] = .string(formatter.string(from: endsAt))
        }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "mandate.grant",
                targetKind: "mandate",
                targetId:   nil,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            _ = try await grant(
                groupId: groupId,
                representativeMembershipId: representativeMembershipId,
                type: type,
                principalType: principalType,
                principalId: principalId,
                endsAt: endsAt
            )
        }
        return outcome
    }

    /// D24P10B — governance-aware revoke. Caller pasa por
    /// `request_or_execute_action('mandate.revoke')`; si admin/founder
    /// con perm `mandates.revoke` el resolver retorna `.directAllowed`
    /// y aquí llamamos `revoke(...)`. Si member solicita, `.decisionOpened`.
    public func revokeViaGovernance(
        groupId: UUID,
        mandateId: UUID,
        reason: String? = nil
    ) async throws -> ActionOutcome {
        let trimmed = reason.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var payload: [String: RPCJSONValue] = [
            "mandate_id": .string(mandateId.uuidString)
        ]
        if let trimmed { payload["reason"] = .string(trimmed) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "mandate.revoke",
                targetKind: "mandate",
                targetId:   mandateId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            try await revoke(mandateId: mandateId, reason: trimmed)
        }
        return outcome
    }
}
