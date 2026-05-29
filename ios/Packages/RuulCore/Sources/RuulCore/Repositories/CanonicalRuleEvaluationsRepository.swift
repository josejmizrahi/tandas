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
}
