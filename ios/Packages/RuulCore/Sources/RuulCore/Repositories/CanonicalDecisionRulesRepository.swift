import Foundation

/// Foundation-scope repository for Primitivas 6/16/22 (Decision rules).
/// Reads via `group_decision_rules(...)` and writes via
/// `set_decision_rules(...)`. iOS never touches `groups.decision_rules`
/// directly.
public struct CanonicalDecisionRulesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func currentDecisionRules(groupId: UUID) async throws -> GroupDecisionRules {
        try await rpc.groupDecisionRules(groupId: groupId)
    }

    /// Trims notes before sending so the wire payload is canonical;
    /// the backend re-trims and stores null when empty.
    ///
    /// V2-G2 sub-slice 8 — canonical surface is `(method, legitimacy)`.
    /// `defaultStyle` is still sent for the legacy column but the
    /// backend derives it from `method` if absent.
    public func setDecisionRules(
        groupId: UUID,
        defaultMethod: DecisionMethod,
        defaultLegitimacySource: LegitimacySource,
        quorumMin: Int? = nil,
        notes: String? = nil
    ) async throws -> GroupDecisionRules {
        let cleanedNotes: String? = {
            guard let notes else { return nil }
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let input = SetDecisionRulesInput(
            pGroupId: groupId,
            pDefaultStyle: defaultMethod.legacyStyle.rawValue,
            pQuorumMin: quorumMin,
            pNotes: cleanedNotes,
            pDefaultMethod: defaultMethod.rawValue,
            pDefaultLegitimacySource: defaultLegitimacySource.rawValue
        )
        return try await rpc.setDecisionRules(input)
    }

    /// V3 PARTE 7c — append-only historial de snapshots. Pre-joined con
    /// el `display_name` del actor. Active-member gate server-side.
    public func history(groupId: UUID, limit: Int = 20) async throws -> [GroupGovernanceVersion] {
        try await rpc.groupGovernanceVersions(groupId: groupId, limit: limit)
    }
}
