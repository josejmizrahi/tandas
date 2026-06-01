import Foundation

/// V2-G3.5: read-only repository for the engine audit feed. iOS never
/// inserts here (the engine itself is append-only); the surface is a
/// single paginated list call.
public struct CanonicalRuleEvaluationsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func evaluations(
        groupId: UUID,
        limit: Int = 50,
        before: Date? = nil
    ) async throws -> [GroupRuleEvaluation] {
        try await rpc.groupRuleEvaluations(groupId: groupId, limit: limit, before: before)
    }

    /// V2-G8.1 — cheap aggregate for the home banner. Returns
    /// `{evaluationsCount, lastEvaluatedAt, hasFailures, windowHours}`.
    public func summary(
        groupId: UUID,
        windowHours: Int = 24
    ) async throws -> GroupRuleEvaluationSummary {
        try await rpc.groupRuleEvaluationSummary(groupId: groupId, windowHours: windowHours)
    }

    /// V2-G8.2 — "¿Por qué pasó esto?" reverse lookup. `found=false`
    /// is a normal answer (event wasn't engine-caused), not an error.
    public func provenance(
        eventUuid: UUID
    ) async throws -> SystemEventProvenance {
        try await rpc.systemEventEngineProvenance(eventUuid: eventUuid)
    }

    // MARK: - V3-D.17

    /// Rich engine summary for `GroupEngineSettingsView`. Distinct
    /// from `summary(...)` which feeds the home banner.
    public func engineSummary(
        groupId: UUID,
        since: Date
    ) async throws -> GroupRuleEngineSummary {
        try await rpc.ruleEvaluationSummary(groupId: groupId, since: since)
    }

    /// Kill switch toggle. Server enforces `engine.toggle` permission.
    public func setEngineActive(
        groupId: UUID,
        active: Bool
    ) async throws -> GroupEngineToggleResult {
        try await rpc.setGroupEngineActive(groupId: groupId, active: active)
    }

    /// D.22 — governance-aware engine toggle. `engine.toggle` is
    /// CONSTITUTIONAL (founder_can_override=false), so this always
    /// opens a decision. Returns `.directAllowed` only in the unlikely
    /// case the catalog is downgraded in the future.
    public func setEngineActiveViaGovernance(
        groupId: UUID,
        active: Bool
    ) async throws -> ActionOutcome {
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "engine.toggle",
                targetKind: "group",
                targetId:   groupId,
                payload:    ["active": .bool(active)]
            )
        )
        if case .directAllowed = outcome {
            _ = try await rpc.setGroupEngineActive(groupId: groupId, active: active)
        }
        return outcome
    }

    /// Read-only quota for the settings view.
    public func engineQuota(
        groupId: UUID
    ) async throws -> GroupRuleEngineQuota? {
        try await rpc.groupRuleEngineQuota(groupId: groupId)
    }
}
