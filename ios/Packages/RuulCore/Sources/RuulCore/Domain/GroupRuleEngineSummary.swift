import Foundation

// MARK: - V3-D.17 — Rule Engine Summary (rich)
//
// Maps the `rule_evaluation_summary(p_group_id, p_since)` jsonb payload
// used by `GroupEngineSettingsView`. Distinct from the V2-G8.1
// `GroupRuleEvaluationSummary` (used by the home banner) — that one is
// 4 fields backed by `group_rule_evaluation_summary(p_group_id,
// p_window_hours)`. This one is the D.16 control-plane payload:
//
// {
//   group_id, since, engine_active,
//   total_evaluations, matched_count, unmatched_count,
//   emitted_actions_count, failed_actions_count,
//   evaluations_by_trigger:   { event_type: count },
//   actions_by_consequence_kind: { kind: count },
//   engine_skipped_breakdown:  { reason: count },
//   top_failing_rules:        [{ ... }]
// }

public struct GroupRuleEngineSummary: Codable, Sendable, Hashable, Equatable {
    public let groupId: UUID
    public let since: Date
    public let engineActive: Bool

    public let totalEvaluations: Int
    public let matchedCount: Int
    public let unmatchedCount: Int

    public let emittedActionsCount: Int
    public let failedActionsCount: Int

    public let evaluationsByTrigger: [String: Int]
    public let actionsByConsequenceKind: [String: Int]
    public let engineSkippedBreakdown: [String: Int]

    enum CodingKeys: String, CodingKey {
        case groupId                   = "group_id"
        case since
        case engineActive              = "engine_active"
        case totalEvaluations          = "total_evaluations"
        case matchedCount              = "matched_count"
        case unmatchedCount            = "unmatched_count"
        case emittedActionsCount       = "emitted_actions_count"
        case failedActionsCount        = "failed_actions_count"
        case evaluationsByTrigger      = "evaluations_by_trigger"
        case actionsByConsequenceKind  = "actions_by_consequence_kind"
        case engineSkippedBreakdown    = "engine_skipped_breakdown"
    }

    public init(
        groupId: UUID,
        since: Date,
        engineActive: Bool,
        totalEvaluations: Int,
        matchedCount: Int,
        unmatchedCount: Int,
        emittedActionsCount: Int,
        failedActionsCount: Int,
        evaluationsByTrigger: [String: Int] = [:],
        actionsByConsequenceKind: [String: Int] = [:],
        engineSkippedBreakdown: [String: Int] = [:]
    ) {
        self.groupId = groupId
        self.since = since
        self.engineActive = engineActive
        self.totalEvaluations = totalEvaluations
        self.matchedCount = matchedCount
        self.unmatchedCount = unmatchedCount
        self.emittedActionsCount = emittedActionsCount
        self.failedActionsCount = failedActionsCount
        self.evaluationsByTrigger = evaluationsByTrigger
        self.actionsByConsequenceKind = actionsByConsequenceKind
        self.engineSkippedBreakdown = engineSkippedBreakdown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.since = try c.decode(Date.self, forKey: .since)
        self.engineActive = try c.decode(Bool.self, forKey: .engineActive)
        self.totalEvaluations = (try c.decodeIfPresent(Int.self, forKey: .totalEvaluations)) ?? 0
        self.matchedCount = (try c.decodeIfPresent(Int.self, forKey: .matchedCount)) ?? 0
        self.unmatchedCount = (try c.decodeIfPresent(Int.self, forKey: .unmatchedCount)) ?? 0
        self.emittedActionsCount = (try c.decodeIfPresent(Int.self, forKey: .emittedActionsCount)) ?? 0
        self.failedActionsCount = (try c.decodeIfPresent(Int.self, forKey: .failedActionsCount)) ?? 0
        self.evaluationsByTrigger = (try c.decodeIfPresent([String: Int].self, forKey: .evaluationsByTrigger)) ?? [:]
        self.actionsByConsequenceKind = (try c.decodeIfPresent([String: Int].self, forKey: .actionsByConsequenceKind)) ?? [:]
        self.engineSkippedBreakdown = (try c.decodeIfPresent([String: Int].self, forKey: .engineSkippedBreakdown)) ?? [:]
    }
}

public extension GroupRuleEngineSummary {
    /// Coarse health classification surfaced as a traffic-light dot in
    /// the engine settings view. Order is determined locally — no
    /// backend judgement embedded.
    enum Health: Sendable, Equatable, Hashable {
        case green
        case yellow
        case red
    }

    var rateLimitedCount: Int { engineSkippedBreakdown["rate_limited"] ?? 0 }
    var killSwitchSkippedCount: Int { engineSkippedBreakdown["engine_inactive"] ?? 0 }

    var health: Health {
        if !engineActive { return .yellow }
        if failedActionsCount > 0 { return .red }
        if rateLimitedCount > 0 { return .yellow }
        return .green
    }
}

// MARK: - Engine quota (read-only in D.17)

/// V3-D.17 — quota row exposed read-only in `GroupEngineSettingsView`.
/// Hydrated directly from `public.group_rule_engine_quotas` (PostgREST
/// REST GET, not an RPC). Editing is intentionally out of scope per
/// founder doctrine: cambiar la cuota es D.18+.
public struct GroupRuleEngineQuota: Codable, Sendable, Hashable, Equatable {
    public let groupId: UUID
    public let maxEvalsPerWindow: Int
    public let windowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case groupId            = "group_id"
        case maxEvalsPerWindow  = "max_evals_per_window"
        case windowSeconds      = "window_seconds"
    }

    public init(groupId: UUID, maxEvalsPerWindow: Int, windowSeconds: Int) {
        self.groupId = groupId
        self.maxEvalsPerWindow = maxEvalsPerWindow
        self.windowSeconds = windowSeconds
    }
}

// MARK: - Toggle result

/// V3-D.17 — return of `set_group_engine_active`. `changed=false`
/// means the call was a no-op (already in the requested state).
public struct GroupEngineToggleResult: Codable, Sendable, Hashable, Equatable {
    public let groupId: UUID
    public let engineActive: Bool
    public let changed: Bool

    enum CodingKeys: String, CodingKey {
        case groupId       = "group_id"
        case engineActive  = "engine_active"
        case changed
    }

    public init(groupId: UUID, engineActive: Bool, changed: Bool) {
        self.groupId = groupId
        self.engineActive = engineActive
        self.changed = changed
    }
}
