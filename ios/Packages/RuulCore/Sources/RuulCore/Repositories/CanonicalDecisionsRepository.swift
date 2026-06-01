import Foundation

/// Foundation-scope repository for Primitiva 16 (Decisions / Voting).
/// Reads via `list_decisions_active(...)` / `list_decisions_history(...)`
/// / `decision_detail(...)`; writes via `start_vote(...)`,
/// `cast_vote(...)`, `finalize_vote(...)` and `cancel_vote(...)`.
///
/// Scheduling (`opens_at`/`closes_at`), threshold/quorum overrides and
/// reference linking (sanction/dispute/mandate/dissolution) are
/// deferred — Foundation only exposes the small set of fields the
/// propose sheet collects.
public struct CanonicalDecisionsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeDecisions(groupId: UUID) async throws -> [GroupDecisionSummary] {
        try await rpc.listDecisionsActive(groupId: groupId)
    }

    public func historyDecisions(groupId: UUID, limit: Int = 50) async throws -> [GroupDecisionSummary] {
        try await rpc.listDecisionsHistory(groupId: groupId, limit: limit)
    }

    public func detail(decisionId: UUID) async throws -> GroupDecisionDetail {
        try await rpc.decisionDetail(decisionId: decisionId)
    }

    /// V3 D.24 P12B-4 — live status read model. Complementa `detail(...)`
    /// con conteos frescos (DISTINCT ON cast_at), my_vote, eligible_voters,
    /// quorum/threshold progress, y execution_status/attempts/error.
    /// Caller puede caer al detail legacy si esta RPC falla.
    public func liveResult(decisionId: UUID) async throws -> DecisionLiveResult {
        try await rpc.decisionLiveResult(decisionId: decisionId)
    }

    public func propose(
        groupId: UUID,
        title: String,
        body: String?,
        decisionType: DecisionType,
        method: DecisionMethod,
        legitimacySource: LegitimacySource,
        referenceKind: String? = nil,
        referenceId: UUID? = nil,
        metadata: [String: RPCJSONValue]? = nil,
        options: [StartVoteParams.OptionDraft]?
    ) async throws -> UUID {
        let input = StartVoteParams(
            groupId: groupId,
            title: title,
            body: body?.trimmedOrNil,
            decisionType: decisionType.rawValue,
            method: method.rawValue,
            legitimacySource: legitimacySource.rawValue,
            referenceKind: referenceKind,
            referenceId: referenceId,
            options: (options?.isEmpty ?? true) ? nil : options,
            metadata: metadata
        )
        return try await rpc.startVote(input)
    }

    public func castVote(
        decisionId: UUID,
        value: VoteValue,
        optionId: UUID? = nil,
        reason: String? = nil,
        weight: Decimal? = nil
    ) async throws -> UUID {
        let input = CastVoteParams(
            decisionId: decisionId,
            optionId: optionId,
            voteValue: value.rawValue,
            reason: reason?.trimmedOrNil,
            weight: weight
        )
        return try await rpc.castVote(input)
    }

    /// V2-G9 — submit a ranked-choice ballot. Backend computes Borda
    /// points (`weight = N - rank`); `rankings` MUST be a non-empty
    /// array of distinct option ids paired with 1-based ranks.
    public func castRankedVote(
        decisionId: UUID,
        rankings: [(optionId: UUID, rank: Int)],
        reason: String? = nil
    ) async throws -> UUID {
        let input = CastRankedVoteParams(
            decisionId: decisionId,
            rankings: rankings.map { .init(optionId: $0.optionId, rank: $0.rank) },
            reason: reason?.trimmedOrNil
        )
        return try await rpc.castRankedVote(input)
    }

    public func finalize(decisionId: UUID) async throws -> String {
        try await rpc.finalizeVote(decisionId: decisionId)
    }

    public func cancel(decisionId: UUID, reason: String? = nil) async throws {
        try await rpc.cancelVote(CancelVoteParams(decisionId: decisionId, reason: reason?.trimmedOrNil))
    }

    // MARK: - V3-D.18

    /// `list_decision_templates()` — governance recipes for the propose
    /// sheet. Static catalog; safe to cache locally per session.
    public func listTemplates() async throws -> [DecisionTemplate] {
        try await rpc.listDecisionTemplates()
    }

    /// `execute_decision(p_decision_id)` — produces the side effects of a
    /// passed decision. Server-gated by `decisions.execute`.
    public func execute(decisionId: UUID) async throws -> ExecuteDecisionResult {
        try await rpc.executeDecision(decisionId: decisionId)
    }

    /// `decision_provenance(p_decision_id)` — manual vs rule + rule
    /// title + consequence kind. `found=false` is a normal answer.
    public func provenance(decisionId: UUID) async throws -> DecisionProvenance {
        try await rpc.decisionProvenance(decisionId: decisionId)
    }

    /// `decision_summary(p_group_id)` — founder dashboard payload.
    public func summary(groupId: UUID) async throws -> DecisionSummary {
        try await rpc.decisionSummary(groupId: groupId)
    }

    /// `apply_decision_template(p_decision_id, p_template_key)` — call
    /// right after `propose(...)` when a template was selected so the
    /// decision carries the template_key + execution_mode.
    public func applyTemplate(
        decisionId: UUID,
        templateKey: String
    ) async throws -> ApplyDecisionTemplateResult {
        try await rpc.applyDecisionTemplate(decisionId: decisionId, templateKey: templateKey)
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
