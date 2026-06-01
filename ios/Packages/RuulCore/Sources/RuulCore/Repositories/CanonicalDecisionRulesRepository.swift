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
        notes: String? = nil,
        defaultThresholdPct: Decimal? = nil,
        defaultQuorumPct: Decimal? = nil,
        defaultDurationHours: Int? = nil,
        autoCloseOnThreshold: Bool? = nil
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
            pDefaultLegitimacySource: defaultLegitimacySource.rawValue,
            pDefaultThresholdPct: defaultThresholdPct,
            pDefaultQuorumPct: defaultQuorumPct,
            pDefaultDurationHours: defaultDurationHours,
            pAutoCloseOnThreshold: autoCloseOnThreshold
        )
        return try await rpc.setDecisionRules(input)
    }

    /// V3 PARTE 7c — append-only historial de snapshots. Pre-joined con
    /// el `display_name` del actor. Active-member gate server-side.
    public func history(groupId: UUID, limit: Int = 20) async throws -> [GroupGovernanceVersion] {
        try await rpc.groupGovernanceVersions(groupId: groupId, limit: limit)
    }

    /// D.22 — governance-aware set. `group.decision_rules.set` is
    /// CONSTITUTIONAL, so this always opens a decision (founder cannot
    /// override). On the unlikely `.directAllowed` we still proceed with
    /// the underlying RPC and return the result via the outcome.
    public func setDecisionRulesViaGovernance(
        groupId: UUID,
        defaultMethod: DecisionMethod,
        defaultLegitimacySource: LegitimacySource,
        quorumMin: Int? = nil,
        notes: String? = nil,
        defaultThresholdPct: Decimal? = nil,
        defaultQuorumPct: Decimal? = nil,
        defaultDurationHours: Int? = nil,
        autoCloseOnThreshold: Bool? = nil
    ) async throws -> ActionOutcome {
        let cleanedNotes: String? = {
            guard let notes else { return nil }
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        var payload: [String: RPCJSONValue] = [
            "default_method": .string(defaultMethod.rawValue),
            "default_legitimacy_source": .string(defaultLegitimacySource.rawValue),
            "default_style": .string(defaultMethod.legacyStyle.rawValue)
        ]
        if let quorumMin {
            payload["quorum_min"] = .number(Decimal(quorumMin))
        }
        if let cleanedNotes {
            payload["notes"] = .string(cleanedNotes)
        }
        if let defaultThresholdPct {
            payload["default_threshold_pct"] = .number(defaultThresholdPct)
        }
        if let defaultQuorumPct {
            payload["default_quorum_pct"] = .number(defaultQuorumPct)
        }
        if let defaultDurationHours {
            payload["default_duration_hours"] = .number(Decimal(defaultDurationHours))
        }
        if let autoCloseOnThreshold {
            payload["auto_close_on_threshold"] = .bool(autoCloseOnThreshold)
        }
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "group.decision_rules.set",
                targetKind: "group",
                targetId:   groupId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            _ = try await setDecisionRules(
                groupId: groupId,
                defaultMethod: defaultMethod,
                defaultLegitimacySource: defaultLegitimacySource,
                quorumMin: quorumMin,
                notes: cleanedNotes,
                defaultThresholdPct: defaultThresholdPct,
                defaultQuorumPct: defaultQuorumPct,
                defaultDurationHours: defaultDurationHours,
                autoCloseOnThreshold: autoCloseOnThreshold
            )
        }
        return outcome
    }
}
